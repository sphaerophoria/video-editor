#version 330

in vec2 vert_coord_2d;
out vec4 fragment;
uniform sampler2D y_tex;
uniform sampler2D u_tex;
uniform sampler2D v_tex;

void main()
{
    vec2 frag_coord = (vert_coord_2d + 1.0) / 2.0;
    frag_coord.y *= -1;

    float y = texture(y_tex, frag_coord).r;
    float u = texture(u_tex, frag_coord).r;
    float v = texture(v_tex, frag_coord).r;

    // https://en.wikipedia.org/wiki/YCbCr#ITU-R_BT.601_conversion
    y -= 16.0 / 255.0;
    v -= 0.5;
    u -= 0.5;
    y *= 255.0 / 219.0;
    u *= 255.0 / 224.0 * 1.772;
    v *= 255.0 / 224.0 * 1.402;
    float r = y + v;
    float g = y - u * 0.114 / 0.587 - v * 0.299 / 0.587;
    float b = y + u;
    fragment = vec4(r, g, b, 1.0);
}

