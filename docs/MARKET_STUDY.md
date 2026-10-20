# OpenViewer — Estudio de mercado

> Fecha: octubre 2026. Alcance: visores de imágenes para iPad (y referentes de escritorio) orientados a
> navegar **carpetas grandes con subcarpetas**. Nota: las búsquedas web dieron poca información reciente y
> fiable sobre este nicho, así que el análisis se apoya sobre todo en el conocimiento de las apps más
> conocidas. Antes de publicar conviene revisar las fichas actuales de la App Store.

## 1. El problema

En iPadOS, la app **Fotos** solo muestra la fototeca y la app **Archivos** no está pensada para ver imágenes:
abre cada archivo en Quick Look, uno por uno, genera las miniaturas despacio y no permite ver
"todas las imágenes de esta carpeta y de sus subcarpetas" de una vez. Cualquiera que tenga miles de imágenes en
un disco externo, una carpeta de iCloud Drive o un recurso SMB no tiene una forma rápida de recorrerlas.

## 2. Panorama de apps

| App | Tipo | Puntos fuertes | Puntos débiles |
|---|---|---|---|
| **Apple Fotos** | Fototeca | Rejilla de 120 fps, transición con zoom, gestos de pellizco para la rejilla | No lee carpetas arbitrarias ni subcarpetas |
| **Apple Archivos + Quick Look** | Gestor de archivos | Acceso a todos los proveedores (iCloud, USB, SMB) | Miniaturas lentas, sin vista recursiva, navegación entre imágenes torpe |
| **Documents (Readdle) / FileBrowser / FE File Explorer / Owlfiles** | Gestores de archivos con visor | SMB/FTP/WebDAV, presentación de diapositivas | Apps pesadas y llenas de funciones; el visor es secundario; publicidad o suscripción |
| **GoodReader** | Lector de documentos | Muy potente con PDF y carpetas | Interfaz anticuada; las imágenes no son lo principal |
| **Lectores de cómics (Panels, Chunky, YACReader)** | Lectores secuenciales | Paso de página instantáneo, precarga, scrubber para saltar | Pensados para archivos CBZ/CBR, no para árboles de carpetas |
| **Visores en la App Store ("Folder Photo Viewer", "Image Viewer", "File Viewer for All", etc.)** | Visores de carpetas | Rejilla y vista recursiva | Calidad irregular, publicidad, en general sin buen rendimiento con 10.000+ imágenes, a veces abandonados (p. ej. *D Image Viewer* anunció su cierre en 2025) |
| **Escritorio: IrfanView, XnView, FastStone, ImageGlass, qView, Apple Vista Previa** | Referentes | Apertura instantánea, precarga de las imágenes contiguas, todo con teclado, ligeros | No existen en iPad |

## 3. Lo mejor de cada una (lo que copiamos)

1. **Fotos**: rejilla densa, pellizco para cambiar el tamaño, transición con zoom desde la miniatura y cierre deslizando hacia abajo.
2. **Lectores de cómics**: precarga de las páginas siguientes, scrubber para saltar a cualquier posición en colecciones enormes.
3. **IrfanView / FastStone / qView**: arranque instantáneo, todo manejable con teclado (flechas, espacio, Esc), sin pantallas intermedias.
4. **Gestores de archivos**: abrir **cualquier** carpeta (iCloud, USB, SMB y proveedores de terceros) sin copiar nada.
5. **Visores recursivos**: un modo "aplanado" con *todas* las imágenes del árbol.
6. **Lightroom/Vista Previa**: panel de información EXIF ligero.

## 4. Lo que NO hacemos (todavía)

Edición, etiquetas, bases de datos, cuentas, sincronización, clientes propios de SMB/FTP (ya los da Archivos),
vídeo. Cada una de estas funciones añade peso y quita velocidad.

## 5. Principios de rendimiento de OpenViewer

| Técnica | Por qué |
|---|---|
| `CGImageSourceCreateThumbnailAtIndex` (ImageIO) con *downsampling* | Decodifica directamente al tamaño de la celda o de la pantalla, nunca la imagen completa. Una foto de 48 MP pasa de ~190 MB a ~1 MB en memoria |
| Uso de la **previsualización incrustada** (EXIF/RAW) cuando tiene resolución suficiente | En JPEG de cámara y en RAW (DNG, CR3, NEF, ARW…) evita decodificar la imagen completa |
| Caché en memoria (`NSCache`) + **caché en disco** de miniaturas (JPEG) | La segunda vez que se abre una carpeta es instantánea |
| Tamaños de miniatura por tramos (256/512/768 px) | Al cambiar de columnas se reutiliza la caché |
| Cola de decodificación con **prioridades y cancelación** | Al hacer scroll rápido no se decodifican celdas que ya no se ven |
| Prefetching de `UICollectionView` | Las miniaturas ya están listas antes de entrar en pantalla |
| UIKit `UICollectionView` (no `LazyVGrid`) | Rendimiento constante con más de 100.000 elementos |
| Escaneo recursivo **en streaming** | Las imágenes aparecen a medida que se encuentran |
| Visor: primero la miniatura y después la imagen a resolución de pantalla, más precarga de ±2 | El cambio de imagen se percibe instantáneo |
| Más resolución solo al hacer zoom | La memoria se mantiene baja hasta que de verdad hace falta |

## 6. Funcionalidades de la v0.1

- Abrir cualquier carpeta con el selector del sistema y guardarla en recientes con *security-scoped bookmarks*; se reabre al iniciar.
- Navegación por subcarpetas con portada y número de elementos, o modo **"Incluir subcarpetas"** (aplanado).
- Rejilla con pellizco o ⌘+/⌘−, orden por nombre natural, fecha o tamaño, y búsqueda por nombre.
- Visor a pantalla completa: deslizar, doble toque para zoom, pellizco, transición con zoom y cierre deslizando hacia abajo.
- Scrubber para saltar en colecciones enormes, presentación de diapositivas (2/3/5/10 s), GIF animados.
- Panel de información con EXIF, compartir, arrastrar y soltar hacia otras apps.
- Teclado: ← → espacio, Inicio/Fin, Esc, I (info), S (presentación).
- Multiventana / Stage Manager, modo oscuro.

## 7. Roadmap propuesto

- Descarga bajo demanda de archivos de iCloud que no están en el dispositivo.
- Vista en tira (*filmstrip*) y comparación de dos imágenes en paralelo.
- Favoritos y valoraciones guardados aparte, sin tocar los archivos.
- Lectura de ZIP/CBZ.
- Salida a pantalla externa.
