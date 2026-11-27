# AvatarParts — formato de assets del avatar modular

Cada carpeta de primer nivel es un **slot** del personaje; cada subcarpeta
es un **estilo** elegible. El compositor (`AvatarComposer`) pega las capas
en orden y genera los `SpriteFrames` del `Player`.

## Estructura

```
AvatarParts/<slot>/<estilo>/<direccion>/{idle.png, walk/frame_XXX.png}
```

- Slots: `skin`, `hair`, `top`, `bottom`, `shoes`, `accessory`.
- Direcciones reales: `south-west` y `north-west`. El compositor genera
  `south-east`/`north-east` espejando (igual que el juego hace hoy).
- `walk/frame_000.png` … `frame_007.png` (8 frames, mismo ciclo que
  `Assets/Sprites/Player/animations/walking/`).
- `idle.png` es opcional; si falta se usa `walk/frame_000.png`.
- `accessory/none` (y cualquier estilo "none") son PNGs 100% transparentes
  del tamaño del canvas — la forma de "slot vacío".

## Reglas de pintado (canvas 64×128, pies alineados con player_iso_*.png)

- **Grises** = zona tintable: el compositor usa el valor como luminancia
  y lo combina con el color elegido (`color * luminance`). Blanco = zona
  más clara, gris oscuro = sombra. Pintá el pelo/ropa tintable en grises.
- **Colores reales** = fijo: ojos, boca, botones, contornos, cordones.
  Nunca se recolorean.
- **Alpha 0** = transparente: deja ver la capa de abajo.
- Todas las capas de un mismo frame deben compartir el canvas exacto
  (64×128) y la misma posición de pies.

## Orden de composición (de atrás hacia adelante)

`skin` → `bottom` → `shoes` → `top` → `hair` → `accessory`

- `skin` incluye la cabeza completa (cráneo, cara, ojos, boca, cejas
  en colores fijos) más cuello, brazos y piernas.

## Flujo en Aseprite

1. Un `.ase` por personaje base con una capa por slot.
2. Tags de animación por capa o por conjunto para los 8 frames de walk.
3. Export por capa+frame a la ruta correspondiente (File → Export →
   Layers/Tags según versión).
