#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;


// --------------------------------------------------
// GPU DATA
// --------------------------------------------------

struct Sphere {
    vec4 center_radius;
    vec4 material;
};

layout(set = 0, binding = 0, std430)

readonly buffer SphereBuffer {
    Sphere spheres[];
};


// Output image
layout(set = 0, binding = 1, rgba8)
uniform writeonly image2D output_image;


// Texture slots
layout(set = 0, binding = 2)
uniform sampler2D texture0;

layout(set = 0, binding = 3)
uniform sampler2D texture1;

layout(set = 0, binding = 4)
uniform sampler2D texture2;

layout(set = 0, binding = 5)
uniform sampler2D texture3;


// --------------------------------------------------
// CAMERA PARAMETERS
// --------------------------------------------------


layout(push_constant, std430) uniform CameraData {

    vec4 camera_origin;
    vec4 camera_right;
    vec4 camera_up;
    vec4 camera_forward;

    // Width, height, aspect ratio, tan(FOV/2).
    vec4 image_info;

    // Number of active spheres.
    vec4 scene_info;

    // Texture rotation angle in radians.
    vec4 texture_info;

} camera;


// --------------------------------------------------
// TEXTURE LOOKUP
// --------------------------------------------------

vec3 sample_material(int material_id, vec2 uv) {

    if (material_id == 0) {
        return texture(texture0, uv).rgb;
    }

    if (material_id == 1) {
        return texture(texture1, uv).rgb;
    }

    if (material_id == 2) {
        return texture(texture2, uv).rgb;
    }

    if (material_id == 3) {
        return texture(texture3, uv).rgb;
    }

    return vec3(1.0, 0.0, 1.0);
}


// --------------------------------------------------
// RAY-SPHERE INTERSECTION
// --------------------------------------------------

float intersect_sphere(
    vec3 ray_origin,
    vec3 ray_direction,
    vec3 sphere_center,
    float sphere_radius
) {

    vec3 oc = ray_origin - sphere_center;

    float b = dot(oc, ray_direction);
    float c = dot(oc, oc) - sphere_radius * sphere_radius;

    float discriminant = b * b - c;

    if (discriminant < 0.0) {
        return -1.0;
    }

    float t = -b - sqrt(discriminant);

    if (t < 0.0) {
        t = -b + sqrt(discriminant);
    }

    if (t < 0.0) {
        return -1.0;
    }

    return t;
}


bool is_in_shadow(
    vec3 hit_position,
    vec3 normal,
    vec3 light_position,
    int sphere_count,
    int current_sphere
) {
    // Move the starting point slightly away from the surface.
    // This prevents the ray from intersecting the sphere it just hit.
    vec3 shadow_origin = hit_position + normal * 0.001;

    vec3 to_light = light_position - shadow_origin;
    float light_distance = length(to_light);
    vec3 shadow_direction = normalize(to_light);

    // Check whether another sphere blocks the light.
    for (int i = 0; i < sphere_count; i++) {

        // Ignore the Sun, current sphere and the background sphere
        if (i == 0 || i == current_sphere || i == 3) {
            continue;
        }

        vec3 center = spheres[i].center_radius.xyz;
        float radius = spheres[i].center_radius.w;

        float t = intersect_sphere(
            shadow_origin,
            shadow_direction,
            center,
            radius
        );

        // An intersection before the light means this point is shadowed.
        if (t > 0.001 && t < light_distance) {
            return true;
        }
    }

    return false;
}


// --------------------------------------------------
// ROTATION FUNCTIONS
// --------------------------------------------------

// Rotate a vector around the X axis.
vec3 rotate_x(vec3 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);

    return vec3(
        v.x,
        c * v.y - s * v.z,
        s * v.y + c * v.z
    );
}


// Rotate a vector around the Y axis.
vec3 rotate_y(vec3 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);

    return vec3(
        c * v.x + s * v.z,
        v.y,
        -s * v.x + c * v.z
    );
}

// --------------------------------------------------
// SPHERICAL TEXTURE COORDINATES
// --------------------------------------------------


vec2 sphere_uv(vec3 normal, float rotation_angle) {
    vec3 n = normalize(normal);

    // Longitude around the Z-axis.
    float longitude = atan(n.y, n.x) - rotation_angle;

    // Convert longitude and latitude to texture coordinates.
    float u = fract(longitude / 6.28318530718 + 0.5);
    float v = acos(clamp(n.z, -1.0, 1.0)) / 3.14159265359;

    return vec2(u, v);
}

// --------------------------------------------------
// MAIN COMPUTE FUNCTION
// --------------------------------------------------

void main() {

    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    ivec2 image_size = imageSize(output_image);

    // Prevent out-of-bounds writes.
    if (pixel.x >= image_size.x ||
        pixel.y >= image_size.y) {
        return;
    }


    // --------------------------------------------------
    // GENERATE CAMERA RAY
    // --------------------------------------------------

    vec2 uv = (vec2(pixel) + vec2(0.5)) /
              vec2(image_size);

    vec2 ndc = uv * 2.0 - 1.0;

    // Flip Y axis to align the ray direction with the camera coordinates.
    ndc.y = -ndc.y;

    float aspect = camera.image_info.z;
    float tan_half_fov = camera.image_info.w;

    vec3 ray_origin = camera.camera_origin.xyz;

    vec3 ray_direction = normalize(
        camera.camera_forward.xyz
        + camera.camera_right.xyz * ndc.x * aspect * tan_half_fov
        + camera.camera_up.xyz * ndc.y * tan_half_fov
    );


    // --------------------------------------------------
    // INTERSECT ALL SPHERES
    // --------------------------------------------------

    
    
    // start with t at infinity
    float closest_t = 3e30;

    int closest_sphere = -1;
    int sphere_count = int(camera.scene_info.x);

    for (int i = 0; i < sphere_count; i++) {
        vec3 center = spheres[i].center_radius.xyz;
        float radius = spheres[i].center_radius.w;
        float t = intersect_sphere(
            ray_origin,
            ray_direction,
            center,
            radius
        );

        if (t > 0.0 && t < closest_t) {

            closest_t = t;
            closest_sphere = i;

        }
    }


    // --------------------------------------------------
    // SHADE
    // --------------------------------------------------

    vec3 color;

    if (closest_sphere >= 0) {

        Sphere sphere = spheres[closest_sphere];

        vec3 hit_position =
            ray_origin + closest_t * ray_direction;

        vec3 normal = normalize(
            hit_position - sphere.center_radius.xyz
        );

        // Retrieve the sphere's individual orientation.
        float rotation_angle = sphere.material.y;
        float orbital_tilt = sphere.material.z;
        float axial_tilt = sphere.material.w;

        int material_id = int(sphere.material.x);

        vec3 texture_normal;

        if (material_id == 2) {
            // The Moon's axial tilt partially cancels its orbital inclination.
            texture_normal = rotate_x(
                normal,
                axial_tilt - orbital_tilt
            );
        }
        else {
            // Earth's axial tilt is relative to the ecliptic plane.
            texture_normal = rotate_y(
                normal,
                -axial_tilt
            );
        }

        // Calculate texture coordinates using the transformed normal.
        vec2 tex_uv = sphere_uv(texture_normal, rotation_angle);

        // Sample the sphere's texture.
        vec3 albedo = sample_material(material_id, tex_uv);

        // Sun and background are not affected by lighting.
        if (material_id == 0 || material_id == 3) {

            color = albedo;

        }
        else {

            // --------------------------------------------------
            // POINT LIGHT AT THE SUN
            // --------------------------------------------------

            vec3 light_position = spheres[0].center_radius.xyz;

            vec3 to_light = light_position - hit_position;

            float light_distance = length(to_light);

            vec3 light_direction = normalize(to_light);

            // Direction from surface toward the camera.
            vec3 view_direction = normalize(
                ray_origin - hit_position
            );

            // Halfway vector between light and view directions.
            vec3 halfway_direction = normalize(
                light_direction + view_direction
            );

            // --------------------------------------------------
            // AMBIENT LIGHTING
            // --------------------------------------------------

            float ambient_strength = 0.06;

            vec3 ambient = ambient_strength * albedo;

            // Check whether another sphere blocks the sunlight.
            bool shadowed = is_in_shadow(
                hit_position,
                normal,
                light_position,
                sphere_count,
                closest_sphere
            );

            // --------------------------------------------------
            // DIFFUSE LIGHTING
            // --------------------------------------------------

            float diffuse_strength = 0.94;

            float diffuse_factor = max(
                dot(normal, light_direction),
                0.0
            );

            vec3 diffuse = vec3(0.0);
            vec3 specular = vec3(0.0);

            // Only calculate direct lighting if the point is not shadowed.
            if (!shadowed && diffuse_factor > 0.0) {

                diffuse = diffuse_strength * diffuse_factor * albedo;

                // PHONG SPECULAR
                vec3 reflect_direction = reflect(-light_direction, normal);

                float specular_strength = 0.25;
                float shininess = 32.0;

                float specular_factor = pow(
                    max(dot(view_direction, reflect_direction), 0.0),
                    shininess
                );

                specular = vec3(1.0) * specular_strength * specular_factor;
            }

            // --------------------------------------------------
            // LIGHT ATTENUATION
            // --------------------------------------------------

            float attenuation = 1.0 /
                (1.0 + 0.025 * light_distance * light_distance);

            // Combine all lighting components.
            color = ambient +
                attenuation * (diffuse + specular);
        }

    }
    else {

        // Background gradient if no sphere is intersected.
        float t = 0.5 * (ray_direction.y + 1.0);

        color = mix(
            vec3(0.05, 0.05, 0.08),
            vec3(0.25, 0.35, 0.5),
            t
        );

    }

    // Finally store the pixel to the image
    imageStore(
        output_image,
        pixel,
        vec4(color, 1.0)
    );
}

