```
.─. .─')             .─. .─')    ('─.  _ .─') _                                  
╲  ( OO )            ╲  ( OO ) _(  OO)( (  OO) )                                 
,──. ,──. ,──. ,──.   ;─────.╲(,──────.╲     .'_   ,─.─')    ,──────. ,──.   ,──.
│  .'   ╱ │  │ │  │   │ .─.  │ │  .───',`'──..._)  │  │OO)('─│ _.───'  ╲  `.'  ╱ 
│      ╱, │  │ │ .─') │ '─' ╱_)│  │    │  │  ╲  '  │  │  ╲(OO│(_╲    .─')     ╱  
│     ' _)│  │_│( OO )│ .─. `.(│  '──. │  │   ' │  │  │(_╱╱  │  '──.(OO  ╲   ╱   
│  .   ╲  │  │ │ `─' ╱│ │  ╲  ││  .──' │  │   ╱ : ,│  │_.'╲_)│  .──' │   ╱  ╱╲_  
│  │╲   ╲('  '─'(_.─' │ '──'  ╱│  `───.│  '──'  ╱(_│  │     ╲│  │_)  `─.╱  ╱.__) 
`──' '──'  `─────'    `──────' `──────'`───────'   `──'      `──'      `──'      
```
# KubeDify: Kubernetes Dify Installer For You

- Install Dify on a k8s with one line command `kubedify install`
- You can run `kubedify install 3.5.0` and rerun it!
- You can run `kubedify install 3.4.1` and just run `kubedify install 3.5.2` , the swtich will be smooth since each version has own PV
- All operations are in your Kind container, you can just delete this container to remove anything

## Quick Start

> Default enterprise image is : dify-enterprise-dev:0.11.3-arm64 , prepare yours in your local images or config it in ` ~/.config/kubedify `

```bash
npm install -g kubedify
#kubedify profile create dev
#kubedify profile use dev
kubedify install 3.5.2
```


