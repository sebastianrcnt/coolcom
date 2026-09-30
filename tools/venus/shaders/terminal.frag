#version 450
struct Cell {uint slot; uint fg; uint bg; uint flags;};
layout(std430,set=0,binding=0) readonly buffer Grid {Cell cells[];};
layout(set=0,binding=1) uniform sampler2D atlas;
layout(set=0,binding=2) uniform sampler2D overlay;
layout(std430,set=0,binding=3) readonly buffer Params {uint width,height,cols,rows,first,cx,cy,cw,overlay_used;} u;
layout(location=0) out vec4 out_color;
vec3 rgb(uint c) {return vec3((c>>16)&255,(c>>8)&255,c&255)/255.0;}
void main() {
    uint x=uint(gl_FragCoord.x),y=uint(gl_FragCoord.y),grid=u.rows*16;
    uint oy=y<grid ? (y+u.first*16)%grid:y;
    uint col=x/8,row=y/16;
    bool here=x<u.cols*8 && y<grid;
    vec3 color=vec3(0);
    vec4 o=u.overlay_used!=0 ? texelFetch(overlay,ivec2(x,oy),0):vec4(0);
    if(o.a>0) color=o.rgb;
    else if(here) {
        Cell c=cells[((row+u.first)%u.rows)*u.cols+col];
        vec3 fg=rgb(c.fg),bg=rgb(c.bg);
        if((c.flags&2)!=0) {vec3 t=fg;fg=bg;bg=t;}
        uint gx=x%8+((c.flags&8)!=0 ? 8:0),gy=y%16;
        ivec2 a=ivec2(c.slot%256*16,c.slot/256*16);
        float cov=texelFetch(atlas,a+ivec2(gx,gy),0).r;
        if((c.flags&1)!=0 && gx>0) cov=max(cov,texelFetch(atlas,a+ivec2(gx-1,gy),0).r);
        if((c.flags&4)!=0 && gy==15) cov=1;
        color=mix(bg,fg,cov);
    }
    if(here && u.cw!=0 && row==u.cy && col>=u.cx && col<u.cx+u.cw) color=1-color;
    out_color=vec4(color,1);
}
