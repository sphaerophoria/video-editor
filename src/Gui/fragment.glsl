#version 330

in vec2 vert_coord_2d;
out vec4 fragment;

uniform float width_ratio = 1.0;
uniform float aspect_ratio_ratio = 1.0;
uniform sampler2D y_tex;
uniform sampler2D u_tex;
uniform sampler2D v_tex;

void main()
{
    // We are somewhere on the screen. We can think of our position as a
    // position relative to the screen, [-1, 1] Texture coordinates are in 0,1,
    // so we have to adjust
    vec2 frag_coord = (vert_coord_2d + 1.0) / 2.0;

    // The input image has a stride and width. The width of the texture is not
    // actually the width of the image, so we have to remap the [0, width] to
    // [0, 1]
    frag_coord.x *= width_ratio;

    // The opengl coordinate system is upside down relative to our image
    // coordinates
    frag_coord.y = 1.0 - frag_coord.y;

    // Here we adjust for the aspect ratio of the window and image. Aspect
    // aspect ratio is the ratio between the window's aspect, and the video's
    // aspect. If the window aspect is smaller (w/h), than we have to add black
    // bars on the top and bottom
    if (aspect_ratio_ratio < 1.0) {
      // Imagine the following scenario...
      // The width of the video, and the width of the window should be the
      // same. So in this case the aspect ratio ratio is just the height of the
      // video over the height of the window.
      //
      // We want to map the entire region to the height of the window, so we
      // divide our y coordinate by ARR to achieve that
      //
      // Before we do though, we slide the image down so that it is centered
      // vertically. This distance is (arr - 1.0 / 2), half the difference
      // between window and video height
      //  ----------------------           ___
      // |______________________|   ___     |
      // |                      |    |      |
      // |                      |    | 1.0  |  aspect_ratio_ratio
      // |                      |    |      |
      // |______________________|   ___     |
      // |                      |           |
      //  ----------------------           ___
      float y_offs = ((aspect_ratio_ratio) - 1.0) / 2.0;
      frag_coord.y += y_offs;
      frag_coord.y /= aspect_ratio_ratio;
    } else {
      // Otherwise we need to add black bars on the right and left
      //
      // Width scaling is more confusing as we need to account for stride != width
      //
      // The width of the video, and the width of the window should be the
      // same. So in this case the aspect ratio ratio is just the width of the
      // window over the width of the video.
      //
      // We have the same logic as with height, however in this situation,
      // we've already remapped our coordinate system so that the maximum value
      // we can see is width_ratio. If we want the to map 1/arr to [0, 1], we
      // need to work relative to width_ratio instead of 1.0

      // |--------1/ARR---------|
      // .   |------1.0-------| .
      // .   |----width-----| . .
      //  ----------------------
      // |   |              |   |
      // |   |              |   |
      // |   |              |   |
      // |   |              |   |
      // |   |              |   |
      // |   |              |   |
      //  ----------------------
      //frag_coord.x /= width_ratio;


      float x_offs = ((width_ratio / aspect_ratio_ratio) - width_ratio) / 2.0;
      frag_coord.x += x_offs;
      frag_coord.x *= aspect_ratio_ratio;
    }

    // Now discard anything out of the bounds of the image
    if (frag_coord.x < 0.0 || frag_coord.x >= width_ratio || frag_coord.y < 0.0 || frag_coord.y >= 1.0) {
      discard;
    }

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

