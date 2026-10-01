#version 450
layout(set=0,binding=0) uniform sampler2D surface;
layout(push_constant) uniform Rect {int x,y,w,h,transparent;} r;
layout(location=0) out vec4 out_color;
void main() {
    ivec2 p=ivec2(gl_FragCoord.xy)-ivec2(r.x,r.y);
    if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,ivec2(r.w,r.h)))) discard;
    vec4 c=texelFetch(surface,p,0);
    if(r.transparent!=0 && c.a==0) discard;
    out_color=vec4(c.rgb,1);
}
