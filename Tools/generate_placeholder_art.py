from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]

OUTLINE = (43, 35, 32, 255)
INK = (30, 24, 22, 255)
CREAM = (246, 231, 200, 255)
PAPER = (250, 244, 226, 255)
SAND = (232, 201, 143, 255)
WOOD_LIGHT = (217, 160, 102, 255)
WOOD = (185, 122, 78, 255)
WOOD_DARK = (122, 75, 50, 255)
WOOD_DEEP = (92, 56, 38, 255)
CORAL = (240, 138, 122, 255)
TEAL = (78, 154, 148, 255)
TEAL_DARK = (56, 116, 112, 255)
MUSTARD = (242, 193, 78, 255)
SKY = (143, 193, 212, 255)
PINK = (242, 167, 195, 255)
SKIN = (246, 217, 184, 255)
SKIN_SHADE = (226, 178, 138, 255)
HAIR = (74, 52, 40, 255)
PANTS = (62, 92, 118, 255)
SHOE = (122, 75, 50, 255)
WALL = (246, 231, 200, 255)
WALL_SHADE = (238, 214, 170, 255)


def px(im: Image.Image, x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if 0 <= x < im.width and 0 <= y < im.height:
        im.putpixel((x, y), color)


def fill_rect(im: Image.Image, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int, int]) -> None:
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px(im, x, y, color)


def stroke_rect(im: Image.Image, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int, int]) -> None:
    for x in range(x0, x1 + 1):
        px(im, x, y0, color)
        px(im, x, y1, color)
    for y in range(y0, y1 + 1):
        px(im, x0, y, color)
        px(im, x1, y, color)


def hline(im: Image.Image, x0: int, x1: int, y: int, color: tuple[int, int, int, int]) -> None:
    for x in range(min(x0, x1), max(x0, x1) + 1):
        px(im, x, y, color)


def vline(im: Image.Image, x: int, y0: int, y1: int, color: tuple[int, int, int, int]) -> None:
    for y in range(min(y0, y1), max(y0, y1) + 1):
        px(im, x, y, color)


def diamond_points(cx: int, cy: int, half_w: int, half_h: int) -> list[tuple[int, int]]:
    return [(cx, cy - half_h), (cx + half_w, cy), (cx, cy + half_h), (cx - half_w, cy)]


def save(im: Image.Image, relative_path: str) -> None:
    path = ROOT / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)
    print(f"wrote {path.relative_to(ROOT)}")


def make_floor_tile() -> Image.Image:
    im = Image.new("RGBA", (64, 32), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    diamond = diamond_points(32, 16, 32, 16)
    draw.polygon(diamond, fill=SAND)

    for y in (8, 16, 24):
        half_width = 2 * min(y, 32 - y)
        hline(im, 32 - half_width, 32 + half_width, y, WOOD_DARK)

    for x, y in ((20, 10), (44, 18), (28, 26), (40, 12)):
        fill_rect(im, x, y, x + 1, y + 1, WOOD)

    draw.line(diamond + [diamond[0]], fill=WOOD_DEEP, width=2)
    inner = diamond_points(32, 16, 29, 13)
    draw.line(inner + [inner[0]], fill=WOOD_LIGHT, width=1)
    return im


def make_block_top() -> Image.Image:
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    fill_rect(im, 0, 0, 31, 31, WOOD_LIGHT)
    stroke_rect(im, 0, 0, 31, 31, WOOD_DEEP)
    stroke_rect(im, 2, 2, 29, 29, WOOD)
    fill_rect(im, 5, 5, 26, 26, PAPER)
    stroke_rect(im, 5, 5, 26, 26, WOOD)
    hline(im, 8, 23, 10, WOOD_LIGHT)
    hline(im, 8, 23, 21, WOOD)
    fill_rect(im, 14, 14, 17, 17, WOOD_LIGHT)
    stroke_rect(im, 14, 14, 17, 17, WOOD)
    return im


def make_block_left() -> Image.Image:
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    fill_rect(im, 0, 0, 31, 31, WOOD)
    fill_rect(im, 0, 0, 31, 1, WOOD_LIGHT)
    fill_rect(im, 0, 30, 31, 31, WOOD_DEEP)
    for y in (8, 16, 24):
        hline(im, 0, 31, y, WOOD_DEEP)
    for y0, seam_x in ((1, 9), (9, 21), (17, 9), (25, 21)):
        vline(im, seam_x, y0, y0 + 5, WOOD_DEEP)
    fill_rect(im, 5, 12, 6, 13, WOOD_DEEP)
    fill_rect(im, 24, 20, 25, 21, WOOD_DEEP)
    stroke_rect(im, 0, 0, 31, 31, OUTLINE)
    return im


def make_block_right() -> Image.Image:
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    fill_rect(im, 0, 0, 31, 31, WOOD_DARK)
    fill_rect(im, 0, 0, 31, 1, WOOD)
    fill_rect(im, 0, 30, 31, 31, WOOD_DEEP)
    for y in (8, 16, 24):
        hline(im, 0, 31, y, WOOD_DEEP)
    for y0, seam_x in ((1, 12), (9, 23), (17, 12), (25, 23)):
        vline(im, seam_x, y0, y0 + 5, WOOD_DEEP)
    fill_rect(im, 7, 11, 8, 12, WOOD_DEEP)
    fill_rect(im, 22, 19, 23, 20, WOOD_DEEP)
    stroke_rect(im, 0, 0, 31, 31, OUTLINE)
    return im


def make_player_placeholder() -> Image.Image:
    im = Image.new("RGBA", (32, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)

    draw.polygon([(9, 9), (12, 2), (16, 8)], fill=CORAL, outline=INK)
    draw.polygon([(16, 8), (20, 2), (23, 9)], fill=CORAL, outline=INK)
    fill_rect(im, 9, 8, 23, 24, SKIN)
    stroke_rect(im, 9, 8, 23, 24, INK)
    fill_rect(im, 8, 7, 24, 9, HAIR)
    fill_rect(im, 8, 7, 10, 12, HAIR)
    fill_rect(im, 22, 7, 24, 12, HAIR)

    fill_rect(im, 13, 14, 14, 15, INK)
    fill_rect(im, 18, 14, 19, 15, INK)
    fill_rect(im, 15, 18, 17, 19, PINK)
    hline(im, 11, 13, 20, INK)
    hline(im, 19, 21, 20, INK)
    hline(im, 10, 12, 22, SKIN_SHADE)
    hline(im, 20, 22, 22, SKIN_SHADE)

    fill_rect(im, 10, 26, 22, 44, TEAL)
    stroke_rect(im, 10, 26, 22, 44, INK)
    fill_rect(im, 13, 26, 19, 29, PAPER)
    fill_rect(im, 15, 34, 16, 35, MUSTARD)
    fill_rect(im, 15, 39, 16, 40, MUSTARD)

    fill_rect(im, 6, 28, 9, 40, SKIN)
    stroke_rect(im, 6, 28, 9, 40, INK)
    fill_rect(im, 6, 28, 9, 31, TEAL)
    fill_rect(im, 23, 28, 26, 40, SKIN)
    stroke_rect(im, 23, 28, 26, 40, INK)
    fill_rect(im, 23, 28, 26, 31, TEAL)

    fill_rect(im, 11, 46, 15, 60, PANTS)
    stroke_rect(im, 11, 46, 15, 60, INK)
    fill_rect(im, 17, 46, 21, 60, PANTS)
    stroke_rect(im, 17, 46, 21, 60, INK)
    fill_rect(im, 10, 60, 16, 63, SHOE)
    stroke_rect(im, 10, 60, 16, 63, INK)
    fill_rect(im, 16, 60, 22, 63, SHOE)
    stroke_rect(im, 16, 60, 22, 63, INK)
    return im


def make_room_background() -> Image.Image:
    im = Image.new("RGBA", (640, 360), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    fill_rect(im, 0, 0, 639, 359, WALL)

    for x in range(40, 640, 80):
        vline(im, x, 0, 248, WALL_SHADE)

    fill_rect(im, 0, 250, 639, 268, WOOD_LIGHT)
    hline(im, 0, 639, 250, WOOD_DARK)
    hline(im, 0, 639, 268, WOOD_DEEP)
    fill_rect(im, 0, 269, 639, 359, SAND)
    for y in range(288, 360, 24):
        hline(im, 0, 639, y, WOOD_DARK)
    for x in range(60, 640, 120):
        vline(im, x, 288, 359, WOOD)

    fill_rect(im, 56, 46, 184, 164, WOOD_DEEP)
    fill_rect(im, 64, 54, 176, 156, SKY)
    fill_rect(im, 64, 54, 176, 84, (168, 214, 228, 255))
    fill_rect(im, 92, 96, 108, 112, MUSTARD)
    fill_rect(im, 140, 120, 156, 136, MUSTARD)
    vline(im, 120, 54, 156, WOOD_DEEP)
    hline(im, 64, 176, 105, WOOD_DEEP)
    fill_rect(im, 48, 42, 64, 168, CORAL)
    fill_rect(im, 176, 42, 192, 168, CORAL)
    stroke_rect(im, 48, 42, 64, 168, OUTLINE)
    stroke_rect(im, 176, 42, 192, 168, OUTLINE)

    fill_rect(im, 420, 62, 540, 150, WOOD_DEEP)
    fill_rect(im, 428, 70, 532, 142, PAPER)
    fill_rect(im, 452, 92, 476, 116, PINK)
    fill_rect(im, 448, 86, 452, 90, PINK)
    fill_rect(im, 476, 86, 480, 90, PINK)
    fill_rect(im, 458, 104, 466, 110, INK)
    fill_rect(im, 492, 96, 516, 120, TEAL)
    fill_rect(im, 496, 100, 512, 116, SKY)
    stroke_rect(im, 420, 62, 540, 150, OUTLINE)

    for x, y in ((260, 70), (300, 120), (350, 60), (390, 140), (250, 180), (560, 210)):
        fill_rect(im, x, y, x + 3, y + 3, MUSTARD)
    return im


def make_furniture_chair() -> Image.Image:
    im = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    fill_rect(im, 16, 12, 48, 34, WOOD)
    stroke_rect(im, 16, 12, 48, 34, INK)
    for x in (22, 30, 38, 46):
        vline(im, x, 14, 32, WOOD_DEEP)
    fill_rect(im, 14, 34, 50, 42, WOOD_LIGHT)
    stroke_rect(im, 14, 34, 50, 42, INK)
    fill_rect(im, 18, 30, 46, 36, TEAL)
    stroke_rect(im, 18, 30, 46, 36, INK)
    fill_rect(im, 16, 42, 22, 58, WOOD_DARK)
    stroke_rect(im, 16, 42, 22, 58, INK)
    fill_rect(im, 42, 42, 48, 58, WOOD_DARK)
    stroke_rect(im, 42, 42, 48, 58, INK)
    return im


def main() -> None:
    save(make_floor_tile(), "Assets/Sprites/Tiles/floor_iso.png")
    save(make_block_top(), "Assets/Sprites/Blocks/block_top.png")
    save(make_block_left(), "Assets/Sprites/Blocks/block_left.png")
    save(make_block_right(), "Assets/Sprites/Blocks/block_right.png")
    import importlib.util
    spec = importlib.util.spec_from_file_location("generate_player_directional_art_v2", Path(__file__).with_name("generate_player_directional_art_v2.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    generate_directional_player = module.main
    save(make_room_background(), "Assets/Backgrounds/room_background.png")
    save(make_furniture_chair(), "Assets/Sprites/Furniture/furniture_chair.png")
    generate_directional_player()


if __name__ == "__main__":
    main()
