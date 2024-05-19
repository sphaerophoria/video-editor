#version 330 core

uniform float zoom = 1.0;
uniform float center = 0.5;
in vec2 in_coord;

void main()
{
  // center adjustment from normalized to ogl space
  float x_coord = in_coord.x - (center - 0.5) * 2;
  x_coord *= zoom;
  gl_Position = vec4(x_coord, in_coord.y, 0.0, 1.0);
}
