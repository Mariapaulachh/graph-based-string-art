// ============================================================
//  String Art Generator  –  Processing
//  Inspirado en el algoritmo de stringar.com
//
//  Cómo usar:
//    1. Pon una imagen (JPG/PNG) en la carpeta /data/ del sketch
//       y escribe su nombre en IMAGE_FILE abajo.
//    2. Ajusta los parámetros en la sección de configuración.
//    3. Ejecuta. El algoritmo dibujará las líneas en tiempo real.
//    4. Tecla ESPACIO → detener / continuar
//       Tecla S       → guardar PNG
//       Tecla R       → reiniciar
// ============================================================

// ---- CONFIGURACIÓN ----------------------------------------
String IMAGE_FILE = "einsteinlengua.png"; // imagen en /data/
int    NUM_PINS   = 200;            // pines en el círculo
int    NUM_LINES  = 3000;           // hilos a trazar
float  LINE_ALPHA = 35;             // opacidad de cada hilo (10-80)
int    CANVAS_SIZE = 700;           // tamaño del lienzo (píxeles)
color  LINE_COLOR  = color(0);      // color del hilo (negro por defecto)
color  BG_COLOR    = color(255);    // fondo (blanco)
int    LINES_PER_FRAME = 10;        // hilos dibujados por fotograma
// -----------------------------------------------------------

PImage src;            // imagen fuente en escala de grises
float[] buffer;        // buffer de oscuridad (float 0-255)
int[]   pinX, pinY;    // coordenadas de cada pin
int     currentPin = 0;
int     lineCount  = 0;
boolean running    = true;
boolean imageLoaded = false;

// Para la visualización de pines ya usados
int[] sequence;        // secuencia de pines generada
int   seqLen = 0;

// ---- Precomputar píxeles de cada segmento pin-a-pin -------
// (se generan bajo demanda y se cachean)
int[][]  segPixels;    // índices de píxeles en el buffer para cada par
boolean[][] computed;  // si ya se calculó ese segmento

void setup() {
  size(700, 700);
  background(BG_COLOR);
  colorMode(RGB, 255);

  // Intentar cargar imagen
  File f = new File(sketchPath("data/" + IMAGE_FILE));
  if (f.exists()) {
    src = loadImage(IMAGE_FILE);
    imageLoaded = true;
    initEngine();
  } else {
    // Imagen de demostración: gradiente circular
    src = createImage(CANVAS_SIZE, CANVAS_SIZE, RGB);
    src.loadPixels();
    for (int y = 0; y < CANVAS_SIZE; y++) {
      for (int x = 0; x < CANVAS_SIZE; x++) {
        float dx = x - CANVAS_SIZE/2.0;
        float dy = y - CANVAS_SIZE/2.0;
        float d  = sqrt(dx*dx + dy*dy) / (CANVAS_SIZE/2.0);
        float v  = constrain(d * 255, 0, 255);
        src.pixels[y * CANVAS_SIZE + x] = color(v);
      }
    }
    src.updatePixels();
    imageLoaded = true;
    initEngine();
  }

  sequence = new int[NUM_LINES + 1];
  sequence[0] = 0;
  frameRate(60);
}

// ---- Preparar buffer y pines ------------------------------
void initEngine() {
  // Redimensionar y convertir a grises
  src.resize(CANVAS_SIZE, CANVAS_SIZE);
  src.filter(GRAY);
  src.loadPixels();

  // Buffer: invertimos para que zonas oscuras → valor alto
  buffer = new float[CANVAS_SIZE * CANVAS_SIZE];
  for (int i = 0; i < buffer.length; i++) {
    float g = red(src.pixels[i]);   // ya es gris, R=G=B
    buffer[i] = 255 - g;            // oscuro = alto
  }

  // Pines equidistantes en círculo
  pinX = new int[NUM_PINS];
  pinY = new int[NUM_PINS];
  float cx = CANVAS_SIZE / 2.0;
  float cy = CANVAS_SIZE / 2.0;
  float r  = CANVAS_SIZE / 2.0 - 2;
  for (int i = 0; i < NUM_PINS; i++) {
    float a = TWO_PI * i / NUM_PINS - HALF_PI;
    pinX[i] = round(cx + r * cos(a));
    pinY[i] = round(cy + r * sin(a));
  }

  // Resetear caché de segmentos
  computed   = new boolean[NUM_PINS][NUM_PINS];
  segPixels  = new int[NUM_PINS][0]; // se llenarán bajo demanda

  currentPin = 0;
  lineCount  = 0;
  seqLen     = 1;
  background(BG_COLOR);
  drawPins();
}

// ---- Obtener píxeles de un segmento (Bresenham) -----------
int[] getSegment(int a, int b) {
  int key = min(a,b) * NUM_PINS + max(a,b);
  // Usamos un mapa simple: si computed[a][b] está seteado devolvemos caché
  if (computed[min(a,b)][max(a,b)]) {
    // Recuperamos de un array auxiliar indexado distinto
    // En su lugar recalculamos rápido (Processing no tiene HashMap fácil para int[])
  }
  // Bresenham
  int x0 = pinX[a], y0 = pinY[a];
  int x1 = pinX[b], y1 = pinY[b];
  int dx = abs(x1 - x0), dy = abs(y1 - y0);
  int sx = (x0 < x1) ? 1 : -1;
  int sy = (y0 < y1) ? 1 : -1;
  int err = dx - dy;
  int count = 0;
  // Primera pasada: contar píxeles
  int tx = x0, ty = y0;
  while (true) {
    count++;
    if (tx == x1 && ty == y1) break;
    int e2 = 2 * err;
    if (e2 > -dy) { err -= dy; tx += sx; }
    if (e2 <  dx) { err += dx; ty += sy; }
  }
  int[] pts = new int[count];
  tx = x0; ty = y0; err = dx - dy;
  for (int k = 0; k < count; k++) {
    if (tx >= 0 && tx < CANVAS_SIZE && ty >= 0 && ty < CANVAS_SIZE)
      pts[k] = ty * CANVAS_SIZE + tx;
    if (tx == x1 && ty == y1) break;
    int e2 = 2 * err;
    if (e2 > -dy) { err -= dy; tx += sx; }
    if (e2 <  dx) { err += dx; ty += sy; }
  }
  return pts;
}

// ---- Puntuación de un segmento: suma del buffer -----------
float scoreSegment(int[] pts) {
  float s = 0;
  for (int idx : pts) s += buffer[idx];
  return s / pts.length;  // promedio para no favorecer segmentos largos
}

// ---- Encontrar el mejor pin destino -----------------------
int bestNext(int from) {
  float best = -1;
  int   bestPin = -1;
  int   skip = max(1, NUM_PINS / 20); // evitar pines adyacentes (~5%)
  for (int t = 0; t < NUM_PINS; t++) {
    if (t == from) continue;
    if (abs(t - from) < skip || abs(t - from) > NUM_PINS - skip) continue;
    float sc = scoreSegment(getSegment(from, t));
    if (sc > best) { best = sc; bestPin = t; }
  }
  return bestPin;
}

// ---- Restar oscuridad del buffer tras trazar un hilo ------
void subtractLine(int[] pts) {
  float sub = 255 * (LINE_ALPHA / 255.0);
  for (int idx : pts) {
    buffer[idx] = max(0, buffer[idx] - sub);
  }
}

// ---- Dibujar los pines en la pantalla --------------------
void drawPins() {
  fill(200, 0, 0);
  noStroke();
  for (int i = 0; i < NUM_PINS; i++) {
    circle(pinX[i], pinY[i], 3);
  }
}

// ---- HUD: información en pantalla ------------------------
void drawHUD() {
  fill(255, 220);
  noStroke();
  rect(0, 0, 220, 58, 0, 0, 8, 0);
  fill(30);
  textSize(12);
  textAlign(LEFT, TOP);
  text("Hilos: " + lineCount + " / " + NUM_LINES, 10, 8);
  text("Pines: " + NUM_PINS + "   Alpha: " + LINE_ALPHA, 10, 26);
  text(running ? "■ generando..." : "❚❚ pausado  [ESPACIO]", 10, 44);
}

// ---- Draw loop -------------------------------------------
void draw() {
  if (!imageLoaded) return;

  if (running && lineCount < NUM_LINES) {
    for (int k = 0; k < LINES_PER_FRAME && lineCount < NUM_LINES; k++) {
      int next = bestNext(currentPin);
      if (next < 0) { running = false; break; }

      // Dibujar hilo
      int[] pts = getSegment(currentPin, next);
      stroke(red(LINE_COLOR), green(LINE_COLOR), blue(LINE_COLOR), LINE_ALPHA);
      strokeWeight(0.8);
      line(pinX[currentPin], pinY[currentPin], pinX[next], pinY[next]);

      subtractLine(pts);
      sequence[seqLen++] = next;
      currentPin = next;
      lineCount++;
    }
  }

  drawHUD();

  if (lineCount >= NUM_LINES && running) {
    running = false;
    println("✓ Generación completa. " + NUM_LINES + " hilos trazados.");
    println("Secuencia de pines guardada en consola.");
    printSequence();
  }
}

// ---- Imprimir secuencia de pines -------------------------
void printSequence() {
  print("Secuencia: ");
  for (int i = 0; i < seqLen; i++) {
    print(sequence[i]);
    if (i < seqLen - 1) print(",");
  }
  println();
}

// ---- Teclado ---------------------------------------------
void keyPressed() {
  if (key == ' ') {
    running = !running;
  }
  if (key == 's' || key == 'S') {
    String fname = "stringart_" + year() + nf(month(),2) + nf(day(),2) +
                   "_" + nf(hour(),2) + nf(minute(),2) + ".png";
    saveFrame(fname);
    println("Guardado: " + fname);
  }
  if (key == 'r' || key == 'R') {
    background(BG_COLOR);
    initEngine();
    running = true;
    seqLen = 1;
  }
  if (key == '+' || key == '=') {
    NUM_PINS = min(NUM_PINS + 20, 500);
    background(BG_COLOR);
    initEngine();
    running = true;
  }
  if (key == '-' || key == '_') {
    NUM_PINS = max(NUM_PINS - 20, 50);
    background(BG_COLOR);
    initEngine();
    running = true;
  }
}
