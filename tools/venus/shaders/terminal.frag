#version 450
struct Cell {uint slot; uint fg; uint bg; uint flags;};
layout(std430,set=0,binding=0) readonly buffer Grid {Cell cells[];};
layout(set=0,binding=1) uniform sampler2D atlas;
layout(set=0,binding=2) uniform sampler2D overlay;
layout(std430,set=0,binding=3) readonly buffer Params {uint width,height,cols,rows,first,cx,cy,cells,overlay_used,cw,ch,per_row,slot_w;} u;
layout(location=0) out vec4 out_color;
vec3 rgb(uint c) {return vec3((c>>16)&255,(c>>8)&255,c&255)/255.0;}
void main() {
    uint x=uint(gl_FragCoord.x),y=uint(gl_FragCoord.y),grid=u.rows*u.ch;
    uint oy=y<grid ? (y+u.first*u.ch)%grid:y;
    uint col=x/u.cw,row=y/u.ch;
    bool here=x<u.cols*u.cw && y<grid;
    vec3 color=vec3(0);
    vec4 o=u.overlay_used!=0 ? texelFetch(overlay,ivec2(x,oy),0):vec4(0);
    if(o.a>0) color=o.rgb;
    else if(here) {
        Cell c=cells[((row+u.first)%u.rows)*u.cols+col];
        vec3 fg=rgb(c.fg),bg=rgb(c.bg);
        if((c.flags&2)!=0) {vec3 t=fg;fg=bg;bg=t;}
        uint gx=x%u.cw+((c.flags&8)!=0 ? u.cw:0),gy=y%u.ch;
        ivec2 a=ivec2(c.slot%u.per_row*u.slot_w,c.slot/u.per_row*u.ch);
        float cov=texelFetch(atlas,a+ivec2(gx,gy),0).r;
        if((c.flags&1)!=0) for(uint b=1;b<=max(1u,u.cw/8u);b++) if(gx>=b) cov=max(cov,texelFetch(atlas,a+ivec2(gx-b,gy),0).r);  // synthetic bold, one pixel per scale step
        if((c.flags&4)!=0 && gy==u.ch-1) cov=1;
        color=mix(bg,fg,cov);
    }
    if(here && u.cells!=0 && row==u.cy && col>=u.cx && col<u.cx+u.cells) color=1-color;
    out_color=vec4(color,1);
}
