#!/usr/bin/env node

const { Command } = require('commander');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const chalkModule = require('chalk');
const chalk = chalkModule.default || chalkModule;
const oraModule = require('ora');
const ora = oraModule.default || oraModule;

const pkg = require('../package.json');

const program = new Command();
program.showHelpAfterError();
const deployScriptPath = path.resolve(__dirname, '..', 'deploy-kind.sh');
const deployScriptDir = path.dirname(deployScriptPath);

const WRITE_COMMANDS = new Set(['install', 'set', 'set-docker-username', 'set-docker-pat', 'profile']);
let installDirWritableWarningShown = false;

function expandHome(p) {
  if (!p) {
    return p;
  }
  if (p.startsWith('~')) {
    const home = os.homedir();
    if (!home) {
      return p;
    }
    if (p === '~') {
      return home;
    }
    if (p.startsWith('~/')) {
      return path.join(home, p.slice(2));
    }
    return path.join(home, p.slice(1));
  }
  return p;
}

function resolveConfigTarget(globalOptions) {
  if (globalOptions?.config) {
    return path.resolve(expandHome(globalOptions.config));
  }

  if (process.env.KUBEDIFY_CONFIG_HOME) {
    return path.resolve(expandHome(process.env.KUBEDIFY_CONFIG_HOME));
  }

  if (process.env.XDG_CONFIG_HOME) {
    return path.resolve(expandHome(process.env.XDG_CONFIG_HOME), 'kubedify');
  }

  const homeDir = os.homedir();
  if (homeDir) {
    return path.resolve(homeDir, '.config', 'kubedify');
  }

  return path.resolve(process.cwd(), '.kubedify');
}

function findExistingAncestor(targetPath) {
  let current = targetPath;
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) {
      break;
    }
    current = parent;
  }
  return current;
}

function isWritablePath(targetPath) {
  const resolved = path.resolve(targetPath);

  try {
    if (fs.existsSync(resolved)) {
      fs.accessSync(resolved, fs.constants.W_OK);
      return true;
    }

    const ancestor = findExistingAncestor(resolved);
    fs.accessSync(ancestor, fs.constants.W_OK);
    return true;
  } catch (error) {
    return false;
  }
}

function ensureWritableTarget(commandName) {
  if (!WRITE_COMMANDS.has(commandName)) {
    return;
  }

  const globalOptions = program.opts();
  const targetPath = resolveConfigTarget(globalOptions);

  if (!globalOptions.config && !process.env.KUBEDIFY_CONFIG_HOME) {
    process.env.KUBEDIFY_CONFIG_HOME = targetPath;
  }

  if (isWritablePath(targetPath)) {
    return;
  }

  if (globalOptions.config) {
    throw new Error(
      `Cannot write to the configuration path ${targetPath}. Ensure the file or its parent directory is writable, or choose another path.`,
    );
  }

  throw new Error(
    `Kubedify cannot write to ${targetPath}. Set KUBEDIFY_CONFIG_HOME or rerun with --config <path> pointing to a writable location.`,
  );
}

function warnIfInstallDirNotWritable() {
  if (installDirWritableWarningShown) {
    return;
  }
  try {
    fs.accessSync(deployScriptDir, fs.constants.W_OK);
  } catch (error) {
    installDirWritableWarningShown = true;
    console.warn(
      chalk.yellow(
        `Install directory ${deployScriptDir} is read-only. Profiles are stored under your user config directory (e.g. ${resolveConfigTarget(program.opts())}). Use --config <path> to point to a different writable location if needed.`,
      ),
    );
  }
}

const WELCOME_ART = [
  ".─. .─')             .─. .─')    ('─.  _ .─') _                                 ",
  "╲  ( OO )            ╲  ( OO ) _(  OO)( (  OO) )                                ",
  ",──. ,──. ,──. ,──.   ;─────.╲(,──────.╲     .'_   ,─.─')    ,──────. ,──.   ,──.",
  "│  .'   ╱ │  │ │  │   │ .─.  │ │  .───',`'──..._)  │  │OO)('─│ _.───'  ╲  `.'  ╱ ",
  "│      ╱, │  │ │ .─') │ '─' ╱_)│  │    │  │  ╲  '  │  │  ╲(OO│(_╲    .─')     ╱  ",
  "│     ' _)│  │_│( OO )│ .─. `.(│  '──. │  │   ' │  │  │(_╱╱  │  '──.(OO  ╲   ╱   ",
  "│  .   ╲  │  │ │ `─' ╱│ │  ╲  ││  .──' │  │   ╱ : ,│  │_.'╲_)│  .──' │   ╱  ╱╲_  ",
  "│  │╲   ╲('  '─'(_.─' │ '──'  ╱│  `───.│  '──'  ╱(_│  │     ╲│  │_)  `─.╱  ╱.__) ",
  "`──' '──'  `─────'    `──────' `──────'`───────'   `──'      `──'      `──'      "
].join('\n');

let welcomeShown = false;

function showWelcome() {
  if (welcomeShown) {
    return;
  }

  welcomeShown = true;
  console.log(chalk.cyan(WELCOME_ART.trimEnd()));
  console.log(chalk.blueBright('Welcome To Use Kubedify'));
  console.log(chalk.blueBright('Kubernetes Dify Installer For You'));
  console.log('');
}

const INSTALL_PROGRESS_STAGES = [
  {
    id: 'config',
    label: 'Loading configuration',
    test: (line) => /Using config file:/i.test(line),
  },
  {
    id: 'mode',
    label: 'Checking execution mode',
    test: (line) => /Dry[- ]run (enabled|disabled)/i.test(line),
  },
  {
    id: 'helm-binary',
    label: 'Validating Helm binary',
    test: (line) => /Using helm binary:/i.test(line),
  },
  {
    id: 'helm-version',
    label: 'Resolving Helm version',
    test: (line) => /Helm (actual )?version/i.test(line),
  },
  {
    id: 'chart-version',
    label: 'Selecting chart version',
    test: (line) => /Helm chart version detected/i.test(line),
  },
  {
    id: 'storage',
    label: 'Preparing storage',
    test: (line) => /Using PVC name:/i.test(line),
  },
  {
    id: 'images',
    label: 'Loading container images',
    test: (line) => /Loading image/i.test(line),
  },
  {
    id: 'pvc',
    label: 'Applying PersistentVolumeClaims',
    test: (line) => /Applying PVC/i.test(line),
  },
  {
    id: 'secret',
    label: 'Updating image pull secret',
    test: (line) => /image pull secret/i.test(line),
  },
  {
    id: 'deploy',
    label: 'Deploying Helm release',
    test: (line) => /Deploying helm release/i.test(line),
  },
  {
    id: 'complete',
    label: 'Finalizing installation',
    test: (line) => /Deployment flow completed/i.test(line),
  },
];

function createInstallProgressTracker(commandName, spinner, baseText) {
  if (commandName !== 'install') {
    return null;
  }

  const stages = INSTALL_PROGRESS_STAGES.map((stage) => ({ ...stage, done: false }));
  const total = stages.length;
  let started = false;
  let finished = false;

  function updateSpinner(force = false) {
    if (!started || (finished && !force)) {
      return;
    }

    const completed = stages.filter((stage) => stage.done).length;
    const remainingStage = stages.find((stage) => !stage.done);
    const percent = Math.round((completed / total) * 100);
    const barWidth = 14;
    const filledWidth = Math.min(barWidth, Math.round((completed / total) * barWidth));
    const emptyWidth = barWidth - filledWidth;
    const bar = `${'█'.repeat(filledWidth)}${'░'.repeat(emptyWidth)}`;
    const nextLabel = remainingStage ? `• ${remainingStage.label}` : '• Completed';
    spinner.text = `${baseText} ${chalk.cyan(`[${bar}] ${percent}%`)} ${remainingStage ? chalk.gray(nextLabel) : chalk.green(nextLabel)}`;
  }

  function start() {
    if (started) {
      return;
    }
    started = true;
    updateSpinner();
  }

  function markDoneThrough(index) {
    for (let i = 0; i <= index && i < stages.length; i += 1) {
      stages[i].done = true;
    }
    updateSpinner();
  }

  function handleLine(line) {
    if (!started || finished) {
      return;
    }

    const matchedIndex = stages.findIndex((stage, index) => !stage.done && stage.test(line));
    if (matchedIndex !== -1) {
      markDoneThrough(matchedIndex);
    }
  }

  function finish(success) {
    if (!started || finished) {
      return;
    }
    finished = true;
    stages.forEach((stage) => {
      stage.done = success ? true : stage.done;
    });
    updateSpinner(true);
  }

  return {
    start,
    handleLine,
    finish,
  };
}

function ensureDeployScript() {
  try {
    fs.accessSync(deployScriptPath, fs.constants.X_OK);
  } catch (error) {
    const message = error.code === 'ENOENT'
      ? `Unable to locate deploy script at ${deployScriptPath}`
      : `Deploy script at ${deployScriptPath} is not executable. Run: chmod +x deploy-kind.sh`;
    throw new Error(message);
  }
}

function buildInvocation(commandName, commandArgs) {
  const invocation = [];
  const globalOptions = program.opts();

  if (globalOptions.config) {
    invocation.push('--config', globalOptions.config);
  }

  if (globalOptions.profile) {
    invocation.push('--profile', globalOptions.profile);
  }

  invocation.push(commandName, ...commandArgs.filter(Boolean).map(String));
  return invocation;
}

function streamLines(readable, formatter, writer, onFirstChunk) {
  let buffer = '';
  let chunkSeen = false;

  readable.on('data', (data) => {
    if (!chunkSeen && typeof onFirstChunk === 'function') {
      chunkSeen = true;
      onFirstChunk();
    }

    buffer += data.toString();
    let newlineIndex;

    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);
      writer(formatter(line.replace(/\r$/, '')) + '\n');
    }
  });

  readable.on('end', () => {
    if (buffer.length) {
      writer(formatter(buffer.replace(/\r$/, '')) + '\n');
    }
  });
}

function formatStdoutLine(line) {
  if (!line) {
    return '';
  }

  return line.replace(/^(\[\d{2}:\d{2}:\d{2}\])/u, (match) => chalk.gray(match));
}

function formatStderrLine(line) {
  if (!line) {
    return '';
  }

  return chalk.red(line);
}

function forwardSignals(child) {
  const signals = ['SIGINT', 'SIGTERM'];
  const handlers = new Map();

  signals.forEach((signal) => {
    const handler = () => {
      if (!child.killed) {
        child.kill(signal);
      }
    };
    handlers.set(signal, handler);
    process.on(signal, handler);
  });

  child.on('close', () => {
    handlers.forEach((handler, signal) => {
      process.removeListener(signal, handler);
    });
  });
}

async function runDeployCommand(commandName, commandArgs, spinnerText) {
  ensureDeployScript();
  warnIfInstallDirNotWritable();
  ensureWritableTarget(commandName);
  const invocation = buildInvocation(commandName, commandArgs);
  const resolvedSpinnerText = spinnerText || `Running ${commandName}...`;
  const spinner = ora({ text: resolvedSpinnerText, color: 'cyan' }).start();
  const progress = createInstallProgressTracker(commandName, spinner, resolvedSpinnerText);
  progress?.start();

  return new Promise((resolve, reject) => {
    let child;

    try {
      child = spawn(deployScriptPath, invocation, { stdio: ['inherit', 'pipe', 'pipe'] });
    } catch (error) {
      spinner.fail(`Failed to launch deploy script: ${error.message}`);
      return reject(error);
    }

    forwardSignals(child);

    let streamingAnnounced = false;

    const announceStreaming = () => {
      if (!streamingAnnounced) {
        streamingAnnounced = true;
        console.log(chalk.cyan('[info] Streaming deploy-kind.sh output...'));
      }
    };

    const stdoutFormatter = (line) => {
      progress?.handleLine(line);
      return formatStdoutLine(line);
    };

    streamLines(child.stdout, stdoutFormatter, (line) => process.stdout.write(line), announceStreaming);
    streamLines(child.stderr, formatStderrLine, (line) => process.stderr.write(line), announceStreaming);

    child.on('error', (error) => {
      progress?.finish(false);
      spinner.fail(`deploy-kind.sh failed: ${error.message}`);
      console.error(chalk.red(`[error] deploy-kind.sh failed: ${error.message}`));
      reject(error);
    });

    child.on('close', (code) => {
      progress?.finish(code === 0);

      if (code === 0) {
        spinner.succeed(`${commandName} completed`);
        console.log(chalk.green(`[ok] ${commandName} completed successfully`));
      } else {
        spinner.fail(`${commandName} failed with exit code ${code}`);
        console.error(chalk.red(`[error] ${commandName} failed with exit code ${code}`));
      }

      if (code === 0) {
        resolve();
      } else {
        const error = new Error(`${commandName} failed`);
        error.exitCode = code;
        reject(error);
      }
    });
  });
}

program
  .name('kubedify')
  .description('A friendly Node.js wrapper for deploy-kind.sh')
  .version(pkg.version)
  .option('--config <path>', 'provide an explicit config path')
  .option('--profile <name>', 'temporarily use a given profile for this invocation');

let commandExecuted = false;
program.hook('preAction', () => {
  commandExecuted = true;
});

program
  .command('install [version]')
  .description('Deploy the chart, optionally pinning the chart version')
  .option('--dry-run', 'show what would happen without applying changes')
  .action(function (version) {
    const options = this.opts();
    const args = [];

    if (version) {
      args.push(version);
    }

    if (options.dryRun) {
      args.push('--dry-run');
    }

    showWelcome();
    return runDeployCommand('install', args, 'Installing Dify on kind...');
  });

program
  .command('set <key> <value...>')
  .description('Update a configuration entry in the active config')
  .action(function (key, values) {
    const args = [key, ...values];
    return runDeployCommand('set', args, `Updating ${key}...`);
  });

program
  .command('set-docker-username <value>')
  .description('Store DOCKER_USERNAME in the active profile secrets file')
  .action(function (value) {
    return runDeployCommand('set-docker-username', [value], 'Updating DOCKER_USERNAME...');
  });

program
  .command('set-docker-pat <value>')
  .description('Store DOCKER_PAT in the active profile secrets file')
  .action(function (value) {
    return runDeployCommand('set-docker-pat', [value], 'Updating DOCKER_PAT...');
  });

program
  .command('list')
  .description('List available chart versions from the configured Helm repo')
  .action(function () {
    return runDeployCommand('list', [], 'Fetching available chart versions...');
  });

program
  .command('current')
  .description('Show the last recorded installed chart version')
  .action(function () {
    return runDeployCommand('current', [], 'Checking the currently installed chart version...');
  });

program
  .command('show')
  .description('Print the active configuration JSON')
  .action(function () {
    return runDeployCommand('show', [], 'Reading active configuration...');
  });

const profile = program
  .command('profile')
  .description('Manage configuration profiles');

profile
  .command('list')
  .description('List known profiles (active profile marked with *)')
  .action(function () {
    return runDeployCommand('profile', ['list'], 'Listing profiles...');
  });

profile
  .command('create <name>')
  .description('Create a new profile configuration from the example template')
  .action(function (name) {
    return runDeployCommand('profile', ['create', name], `Creating profile ${name}...`);
  });

profile
  .command('delete <name>')
  .description('Delete a profile configuration directory')
  .action(function (name) {
    return runDeployCommand('profile', ['delete', name], `Deleting profile ${name}...`);
  });

profile
  .command('use <name>')
  .description('Switch the default profile used by subsequent runs')
  .action(function (name) {
    return runDeployCommand('profile', ['use', name], `Switching to profile ${name}...`);
  });

async function main() {
  try {
    await program.parseAsync(process.argv);
    if (!commandExecuted) {
      showWelcome();
      await runDeployCommand('install', [], 'Installing Dify on kind...');
    }
  } catch (error) {
    if (error.exitCode !== undefined) {
      process.exit(error.exitCode);
    }
    console.error(chalk.red(`[error] ${error.message}`));
    process.exit(1);
  }
}

main();
