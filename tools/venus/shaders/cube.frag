#version 450
// Analytic ray/box intersections: real perspective, occlusion and lighting without
// a mesh/texture loader. Camera and animation come from the Cool application.
layout(push_constant) uniform Params {
    uint width; uint height; int timeMs; int yawMilli;
    int pitchMilli; int distanceMilli; int panXMilli; int panYMilli;
} p;
layout(location = 0) out vec4 color;
mat3 rotateY(float a) {
    float c = cos(a), s = sin(a);
    return mat3(c, 0, -s, 0, 1, 0, s, 0, c);
}
mat3 rotateX(float a) {
    float c = cos(a), s = sin(a);
    return mat3(1, 0, 0, 0, c, s, 0, -s, c);
}
float boxHit(vec3 ro, vec3 rd, vec3 size, out vec3 normal) {
    // Avoid 0/0 for axis-aligned cameras; slab intersections include inside rays.
    vec3 inv = 1.0 / mix(vec3(-1e-7), vec3(1e-7), greaterThanEqual(rd, vec3(0)));
    for (int i = 0; i < 3; ++i) if (abs(rd[i]) > 1e-7) inv[i] = 1.0 / rd[i];
    vec3 a = (-size - ro) * inv, b = (size - ro) * inv;
    vec3 near = min(a, b), far = max(a, b);
    float enter = max(max(near.x, near.y), near.z);
    float leave = min(min(far.x, far.y), far.z);
    if (leave < max(enter, 0.0)) return 1e5;
    bool inside = enter < 0.0;
    vec3 plane = inside ? far : near;
    float t = inside ? leave : enter;
    normal = vec3(0);
    int axis = abs(plane.x - t) < 1e-4 ? 0 : (abs(plane.y - t) < 1e-4 ? 1 : 2);
    normal[axis] = (inside ? 1.0 : -1.0) * sign(rd[axis]);
    return t;
}
void main() {
    vec2 uv = (2.0 * gl_FragCoord.xy - vec2(p.width, p.height)) / float(p.height);
    uv.y = -uv.y;
    float time = float(p.timeMs) * 0.001;
    float yaw = float(p.yawMilli) * 0.001, pitch = float(p.pitchMilli) * 0.001;
    vec3 target = vec3(float(p.panXMilli) * 0.001, 0.4 + float(p.panYMilli) * 0.001, 0);
    vec3 eye = target + float(p.distanceMilli) * 0.001 * vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
    vec3 forward = normalize(target - eye), right = normalize(cross(forward, vec3(0, 1, 0)));
    vec3 up = cross(right, forward), ray = normalize(forward * 1.65 + right * uv.x + up * uv.y);
    vec3 light = normalize(vec3(-0.45, 0.85, 0.6));
    vec3 sky = mix(vec3(0.016, 0.025, 0.06), vec3(0.075, 0.12, 0.20), clamp(0.45 - ray.y, 0.0, 1.0));
    float closest = 1e5;
    vec3 rgb = sky;
    float floorT = (-1.1 - eye.y) / ray.y;
    if (ray.y < -1e-5 && floorT > 0.0) {
        closest = floorT;
        vec3 hit = eye + floorT * ray;
        vec2 grid = abs(fract(hit.xz * 0.5 - 0.5) - 0.5) / max(fwidth(hit.xz * 0.5), vec2(0.001));
        float line = 1.0 - clamp(min(grid.x, grid.y), 0.0, 1.0);
        rgb = mix(vec3(0.028, 0.045, 0.065), vec3(0.10, 0.23, 0.28), line * 0.65);
        float ring = exp(-35.0 * abs(length(hit.xz) - 1.85));
        rgb += vec3(0.02, 0.45, 0.58) * ring;
        // The central cube casts a hard directional shadow on the grid.
        mat3 rotation = rotateY(time * 0.55) * rotateX(0.25 + sin(time * 0.4) * 0.18);
        vec3 n;
        if (boxHit(transpose(rotation) * (hit - vec3(0, 0.15, 0)), transpose(rotation) * light, vec3(0.88), n) < 1e4) rgb *= 0.32;
        rgb = mix(sky, rgb, exp(-floorT * 0.035));
    }
    for (int object = 0; object < 3; ++object) {
        vec3 center = vec3(0, 0.15, 0), size = vec3(0.88);
        mat3 rotation = rotateY(time * 0.55) * rotateX(0.25 + sin(time * 0.4) * 0.18);
        vec3 base = vec3(0.12, 0.53, 0.85);
        if (object == 1) { center = vec3(-2.65, -0.6, -0.8); size = vec3(0.5); rotation = rotateY(-0.3); base = vec3(0.95, 0.31, 0.12); }
        if (object == 2) { center = vec3(2.65, -0.75, -1.5); size = vec3(0.35); rotation = rotateY(0.5); base = vec3(0.25, 0.85, 0.55); }
        vec3 localEye = transpose(rotation) * (eye - center), localRay = transpose(rotation) * ray, normal;
        float t = boxHit(localEye, localRay, size, normal);
        if (t < closest) {
            closest = t;
            vec3 local = localEye + t * localRay, n = rotation * normal;
            vec3 face = abs(local / size);
            // Distance to the second-nearest face gives thin bright cube edges.
            float edge = min(max(face.x, face.y), min(max(face.y, face.z), max(face.z, face.x)));
            float outline = smoothstep(0.95, 0.99, edge);
            float diffuse = max(dot(n, light), 0.0);
            float specular = pow(max(dot(reflect(-light, n), -ray), 0.0), 48.0);
            rgb = base * (0.22 + 0.78 * diffuse) + vec3(specular * 0.4);
            rgb = mix(rgb, vec3(0.7, 0.95, 1.0), outline * 0.8);
            rgb = mix(sky, rgb, exp(-t * 0.02));
        }
    }
    float vignette = 1.0 - 0.12 * dot(uv, uv);
    color = vec4(pow(max(rgb * max(vignette, 0.55), vec3(0)), vec3(0.85)), 1);
}
