shader_type canvas_item;

uniform float saturation : hint_range(0.0, 1.0) = 0.2;
uniform float brightness : hint_range(0.0, 2.0) = 0.65;
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
uniform float blur : hint_range(0.0, 4.0) = 2.0;
uniform float strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (blur * strength > 0.001) {
		vec2 px = TEXTURE_PIXEL_SIZE * blur * strength;
		vec4 acc = tex * 4.0;
		acc += texture(TEXTURE, UV + vec2(px.x, 0.0)) * 2.0;
		acc += texture(TEXTURE, UV - vec2(px.x, 0.0)) * 2.0;
		acc += texture(TEXTURE, UV + vec2(0.0, px.y)) * 2.0;
		acc += texture(TEXTURE, UV - vec2(0.0, px.y)) * 2.0;
		acc += texture(TEXTURE, UV + px);
		acc += texture(TEXTURE, UV - px);
		acc += texture(TEXTURE, UV + vec2(px.x, -px.y));
		acc += texture(TEXTURE, UV + vec2(-px.x, px.y));
		tex = acc / 16.0;
	}
	vec4 color = tex * COLOR;
	float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
	float sat_mix = mix(0.6, saturation, pow(strength, 1.0));
	float bright_mix = mix(1.0, brightness, pow(strength, 1.0));
	color.rgb = mix(vec3(luma), color.rgb, sat_mix) * bright_mix;
	color.a *= mix(1.0, alpha, strength);
	COLOR = color;
}
