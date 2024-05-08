#version 330 core

out vec2 vert_coord_2d;
void main()
{
  const vec4 vertices[4] = vec4[](
    vec4(-1.0, -1.0, 0.0, 1.0),
    vec4(1.0, -1.0, 0.0, 1.0),
    vec4(-1.0, 1.0, 0.0, 1.0),
    vec4(1.0, 1.0, 0.0, 1.0)
  );
  vert_coord_2d = vec2(vertices[gl_VertexID].x, vertices[gl_VertexID].y);
  gl_Position = vertices[gl_VertexID];
}
