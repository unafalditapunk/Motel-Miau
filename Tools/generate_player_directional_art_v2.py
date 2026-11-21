from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "Assets" / "Sprites" / "Player"

INK = (30, 24, 22, 255)
OUTLINE = (43, 35, 32, 255)
SKIN = (246, 217, 184, 255)
HAIR = (74, 52, 40, 255)
TEAL = (78, 154, 148, 255)
PANTS = (62, 92, 118, 255)
SHOE = (122, 75, 50, 255)
CORAL = (240, 138, 122, 255)
PINK = (242, 167, 195, 255)

TILE_W = 64.0
TILE_H = 32.0
UNIT_H = 32.0

DIRECTIONS = {
    "down_right": (1, 0),
    "up_left": (-1, 0),
    "down_left": (0, 1),
    "up_right": (0, -1),
}


def clamp255(v: float) -> int:
    return max(0, min(255, int(round(v))))


def shade(color: tuple[int, int, int, int], amount: float) -> tuple[int, int, int, int]:
    r, g, b, a = color
    if amount >= 0.0:
        r = r + (255 - r) * amount
        g = g + (255 - g) * amount
        b = b + (255 - b) * amount
    else:
        r = r * (1.0 + amount)
        g = g * (1.0 + amount)
        b = b * (1.0 + amount)
    return (clamp255(r), clamp255(g), clamp255(b), a)


def project(x: float, y: float, z: float) -> tuple[float, float]:
    return ((x - y) * TILE_W * 0.5, (x + y) * TILE_H * 0.5 - z * UNIT_H)


def rot90(v: tuple[int, int]) -> tuple[int, int]:
    return (-v[1], v[0])


def box_grid_rect(u0: float, u1: float, v0: float, v1: float, facing: tuple[int, int]) -> tuple[float, float, float, float]:
    right = rot90(facing)
    xs = []
    ys = []
    for u in (u0, u1):
        for v in (v0, v1):
            x = u * right[0] + v * facing[0]
            y = u * right[1] + v * facing[1]
            xs.append(x)
            ys.append(y)
    return (min(xs), min(ys), max(xs), max(ys))


def box_polys(rect: tuple[float, float, float, float], z0: float, z1: float):
    x0, y0, x1, y1 = rect
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    bottom = [project(x, y, z0) for x, y in corners]
    top = [project(x, y, z1) for x, y in corners]
    front_idx = max(range(4), key=lambda i: (bottom[i][1], bottom[i][0]))
    n1 = (front_idx - 1) % 4
    n2 = (front_idx + 1) % 4
    bf = bottom[front_idx]
    bt = top[front_idx]
    b1 = bottom[n1]
    t1 = top[n1]
    b2 = bottom[n2]
    t2 = top[n2]
    return {
        "top": top,
        "side_a": [bf, b1, t1, bt],
        "side_b": [bf, bt, t2, b2],
        "bottom": bottom,
        "front_idx": front_idx,
    }


def draw_poly(draw: ImageDraw.ImageDraw, points, color) -> None:
    draw.polygon([(round(x), round(y)) for x, y in points], fill=color)


def stroke_poly(draw: ImageDraw.ImageDraw, points, color=OUTLINE, width: int = 1) -> None:
    pts = [(round(x), round(y)) for x, y in points]
    draw.line(pts + [pts[0]], fill=color, width=width)


def centroid(points) -> tuple[float, float]:
    return (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))


def build_character(facing: tuple[int, int]):
    parts = []

    for side in (-1, 1):
        u_center = side * 0.22
        u0, u1 = u_center - 0.10, u_center + 0.10
        v0, v1 = -0.11, 0.11
        parts.append(((u0, u1, v0, v1), 0.0, 0.22, SHOE))
        parts.append(((u0, u1, v0, v1), 0.22, 0.80, PANTS))

    arm_parts = []
    for side in (-1, 1):
        u_center = side * 0.34
        u0, u1 = u_center - 0.09, u_center + 0.09
        v0, v1 = -0.08, 0.08
        arm_parts.append(((u0, u1, v0, v1), 0.80, 1.30, SKIN))

    def arm_depth(part):
        (au0, au1, av0, av1), _, _, _ = part
        rect = box_grid_rect(au0, au1, av0, av1, facing)
        return (rect[0] + rect[2]) * 0.5 + (rect[1] + rect[3]) * 0.5

    arm_parts.sort(key=arm_depth)
    parts.append(arm_parts[0])
    parts.append(((-0.27, 0.27, -0.16, 0.26), 0.70, 1.50, TEAL))
    parts.append(arm_parts[1])

    parts.append(((-0.30, 0.30, -0.20, 0.32), 1.50, 1.95, SKIN))
    parts.append(((-0.30, 0.30, -0.28, -0.02), 1.88, 2.02, HAIR))

    for side in (-1, 1):
        u_center = side * 0.17
        u0, u1 = u_center - 0.06, u_center + 0.06
        v0, v1 = 0.10, 0.22
        parts.append(((u0, u1, v0, v1), 1.95, 2.12, CORAL))

    all_points = []
    boxes = []
    for (u0, u1, v0, v1), z0, z1, color in parts:
        rect = box_grid_rect(u0, u1, v0, v1, facing)
        boxes.append((rect, z0, z1, color))
        corners = [(rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3]), (rect[0], rect[3])]
        for x, y in corners:
            for z in (z0, z1):
                all_points.append(project(x, y, z))

    visible_u_sign = 1.0 if (facing[0] - facing[1]) > 0 else -1.0
    screen_x_sign = -1.0 if (facing[0] + facing[1]) > 0 else 1.0
    torso_shift_x = visible_u_sign * screen_x_sign

    min_x = min(p[0] for p in all_points)
    max_x = max(p[0] for p in all_points)
    min_y = min(p[1] for p in all_points)
    max_y = max(p[1] for p in all_points)

    margin = 2.0
    available_width = 32.0 - margin * 2.0
    available_height = 64.0 - margin * 2.0
    scale = min(1.0, available_width / max(0.001, max_x - min_x), available_height / max(0.001, max_y - min_y))
    offset_x = 16.0 - (min_x + max_x) * scale * 0.5
    offset_y = (64.0 - margin) - max_y * scale

    def transform(point: tuple[float, float]) -> tuple[float, float]:
        return (point[0] * scale + offset_x, point[1] * scale + offset_y)

    im = Image.new("RGBA", (32, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    head_polys = None

    for rect, z0, z1, color in boxes:
        polys = box_polys(rect, z0, z1)
        if z1 == 1.95 and color == SKIN:
            head_polys = polys
        for key in ("side_b", "side_a", "top"):
            shifted = [transform(point) for point in polys[key]]
            if color == TEAL or color == PANTS:
                shifted = [(pt[0] + torso_shift_x, pt[1]) for pt in shifted]
            if key == "top":
                draw_poly(draw, shifted, shade(color, 0.18))
            elif key == "side_a":
                draw_poly(draw, shifted, shade(color, -0.08))
            else:
                draw_poly(draw, shifted, shade(color, -0.22))
        for key in ("side_a", "side_b", "top"):
            shifted = [transform(point) for point in polys[key]]
            if color == TEAL or color == PANTS:
                shifted = [(pt[0] + torso_shift_x, pt[1]) for pt in shifted]
            stroke_poly(draw, shifted, OUTLINE, 1)

    if head_polys is not None and facing[0] + facing[1] > 0:
        _draw_face(draw, head_polys, facing, transform)

    return im, offset_x, offset_y, boxes


def _draw_face(draw: ImageDraw.ImageDraw, head_polys, facing: tuple[int, int], transform) -> None:
    side_polys = {
        "side_a": [transform(point) for point in head_polys["side_a"]],
        "side_b": [transform(point) for point in head_polys["side_b"]],
    }
    top_points = [transform(point) for point in head_polys["top"]]
    all_points = top_points + side_polys["side_a"] + side_polys["side_b"]
    center = centroid(all_points)

    direction = project(facing[0], facing[1], 0.0)
    length = (direction[0] ** 2 + direction[1] ** 2) ** 0.5
    if length <= 0.0:
        return
    dx = direction[0] / length
    dy = direction[1] / length

    best_poly = None
    best_center = None
    best_score = -1.0e9
    for poly in side_polys.values():
        poly_center = centroid(poly)
        vx = poly_center[0] - center[0]
        vy = poly_center[1] - center[1]
        score = vx * dx + vy * dy
        if score > best_score:
            best_score = score
            best_poly = poly
            best_center = poly_center
    if best_poly is None or best_center is None:
        return

    face_x = best_center[0] + dx * 1.5
    face_y = best_center[1] + dy * 1.5 + 1.0
    px = -dy
    py = dx

    for side in (-1.0, 1.0):
        eye_x = face_x + px * side * 2.6
        eye_y = face_y + py * side * 2.6
        draw.rectangle(
            [round(eye_x) - 1, round(eye_y) - 1, round(eye_x) + 1, round(eye_y) + 1],
            fill=INK,
        )

    nose_x = face_x + dx * 1.4
    nose_y = face_y + dy * 1.4
    draw.rectangle(
        [round(nose_x) - 1, round(nose_y), round(nose_x) + 1, round(nose_y) + 1],
        fill=PINK,
    )

    mouth_x = face_x + dx * 2.2
    mouth_y = face_y + dy * 2.2 + 1.0
    draw.rectangle(
        [round(mouth_x) - 1, round(mouth_y), round(mouth_x) + 1, round(mouth_y)],
        fill=INK,
    )


def save(im: Image.Image, name: str) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / name
    im.save(path)
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    for name, facing in DIRECTIONS.items():
        im, ox, oy, _ = build_character(facing)
        save(im, f"player_iso_{name}.png")
        print(name, "offset", ox, oy)


if __name__ == "__main__":
    main()
