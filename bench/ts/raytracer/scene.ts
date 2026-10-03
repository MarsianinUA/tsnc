export const SCENE = `
# A marble ball on a checkered floor between a chrome ball, a glass ball and a wooden box, a row
# of small balls in front, hills behind and a lamp that drifts to the right frame by frame.
camera eye=0,2.2,7.5 target=0,0.3,0 height=0.55
sky horizon=0.85,0.88,0.95 zenith=0.35,0.55,0.9
ambient 0.12,0.12,0.14
light at=-6,9,7 color=0.85,0.8,0.75
light at=7,6,-2 color=0.35,0.4,0.55

material floor diffuse texture=checker color=0.85,0.85,0.8 color2=0.2,0.25,0.3 scale=1 reflect=0.15
material hills diffuse texture=strata color=0.25,0.45,0.2 color2=0.95,0.95,0.97 from=0.4 to=1.8
material stone diffuse texture=marble color=0.92,0.9,0.86 color2=0.3,0.32,0.42 scale=0.9 specular=0.5 shininess=40
material oak diffuse texture=wood color=0.6,0.38,0.2 color2=0.35,0.2,0.1 scale=7 specular=0.2 shininess=16
material chrome mirror color=0.9,0.92,0.95 specular=0.8 shininess=96
material glass glass color=0.96,0.98,1 ior=1.5 specular=0.9 shininess=128
material lamp diffuse color=1,0.85,0.55 emit=0.9,0.75,0.4
material red diffuse color=0.85,0.2,0.15 specular=0.4 shininess=24
material blue diffuse color=0.15,0.3,0.85 specular=0.4 shininess=24 reflect=0.3

plane normal=0,1,0 offset=-1 material=floor
terrain origin=-12,-0.6,-28 size=24 cells=28 height=3 material=hills
icosphere center=0,0.4,0 radius=1.4 depth=3 material=stone
icosphere center=-2.9,-0.1,0.9 radius=0.9 depth=2 material=chrome
sphere center=2.5,-0.2,1.5 radius=0.8 material=glass
box min=1.6,-1,-1.8 max=3.4,0.7,-0.2 material=oak
spheres from=-3.6,-0.75,3.2 step=0.8,0,0 count=10 radius=0.25 material=red
spheres from=-3.2,-0.75,4 step=0.8,0,0 count=9 radius=0.25 material=blue
sphere center=-1.6,2.4,-1.2 radius=0.35 material=lamp move=0.5,0,0
`;
