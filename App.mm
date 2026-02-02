#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>

#define FFT_SIZE 4096
#define FFT_LOG2 12
#define WF_COLS 300
#define WF_ROWS 400

static BOOL gPaused = NO;

// ========== SPECTRUM VIEW ==========
@interface SpectrumView : NSView {
  float _smoothMags[FFT_SIZE / 2];
  float _peaks[FFT_SIZE / 2];
  float _snapshotMags[FFT_SIZE / 2];
  BOOL _showingSnapshot;
}
@property(assign) NSPoint mousePos;
@property(assign) BOOL mouseIn;
- (void)displaySnapshot:(float *)mags count:(int)count;
- (void)clearSnapshot;
@end

// ========== WATERFALL VIEW - OPTIMIZED ==========
@interface WaterfallView : NSView {
  NSBitmapImageRep *_bitmap;
  int _writeCol;
  float _magHistory[WF_COLS]
                   [FFT_SIZE / 2]; // Store FFT magnitudes for each column
  int _selectedCol; // Currently selected column (-1 = none, show live)
}
@property(assign) NSPoint mousePos;
@property(assign) BOOL mouseIn;
@property(assign)
    SpectrumView *spectrumView; // Reference to spectrum view for click updates
- (void)clearSelection;
@end

@implementation WaterfallView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _bitmap =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:WF_COLS
                                                pixelsHigh:WF_ROWS
                                             bitsPerSample:8
                                           samplesPerPixel:3
                                                  hasAlpha:NO
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:WF_COLS * 3
                                              bitsPerPixel:24];
    _writeCol = WF_COLS - 1; // Start at right edge
    _selectedCol = -1;       // No selection by default (show live spectrum)

    // Fill with dark blue and initialize history
    unsigned char *data = [_bitmap bitmapData];
    for (int i = 0; i < WF_COLS * WF_ROWS * 3; i += 3) {
      data[i] = 5;
      data[i + 1] = 5;
      data[i + 2] = 25;
    }
    memset(_magHistory, 0, sizeof(_magHistory));

    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                      NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
  }
  return self;
}

- (void)mouseEntered:(NSEvent *)e {
  _mouseIn = YES;
  [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)e {
  _mouseIn = NO;
  [self setNeedsDisplay:YES];
}
- (void)mouseMoved:(NSEvent *)e {
  _mousePos = [self convertPoint:[e locationInWindow] fromView:nil];
  [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)e {
  NSPoint pt = [self convertPoint:[e locationInWindow] fromView:nil];
  CGFloat marginL = 45;
  CGFloat W = self.bounds.size.width - marginL;

  if (pt.x > marginL && pt.x < marginL + W) {
    // Calculate which column was clicked
    float xNorm = (pt.x - marginL) / W;
    int col = (int)(xNorm * WF_COLS);

    // Toggle behavior: if clicking close to current selection (within 5
    // columns), clear it
    if (_selectedCol != -1 && abs(col - _selectedCol) < 5) {
      [self clearSelection];
    } else if (col >= 0 && col < WF_COLS) {
      _selectedCol = col;
      // Update the spectrum view with the historical data at this column
      if (_spectrumView) {
        [_spectrumView displaySnapshot:_magHistory[col] count:FFT_SIZE / 2];
      }
      [self setNeedsDisplay:YES];
    }
  }
}

- (void)clearSelection {
  _selectedCol = -1;
  if (_spectrumView) {
    [_spectrumView clearSnapshot];
  }
  [self setNeedsDisplay:YES];
}

- (void)addColumn:(float *)mags count:(int)count {
  if (gPaused)
    return;

  unsigned char *data = [_bitmap bitmapData];
  int bytesPerRow = (int)[_bitmap bytesPerRow];

  // Shift magnitude history LEFT (oldest is at index 0, newest at WF_COLS-1)
  for (int col = 0; col < WF_COLS - 1; col++) {
    memcpy(_magHistory[col], _magHistory[col + 1],
           (FFT_SIZE / 2) * sizeof(float));
  }
  // Store new magnitudes at the right edge
  for (int i = 0; i < count && i < FFT_SIZE / 2; i++) {
    _magHistory[WF_COLS - 1][i] = mags[i];
  }

  // Shift all columns LEFT by one
  for (int row = 0; row < WF_ROWS; row++) {
    memmove(data + row * bytesPerRow, data + row * bytesPerRow + 3,
            (WF_COLS - 1) * 3);
  }

  // Write new column at RIGHT edge
  float binHz = 44100.0f / FFT_SIZE;
  float minLog = log10f(30.0f);
  float maxLog = log10f(12000.0f);
  float rangeLog = maxLog - minLog;

  for (int row = 0; row < WF_ROWS; row++) {
    float yNorm = (float)row / WF_ROWS;
    float freq = powf(10.0f, yNorm * rangeLog + minLog);
    int bin = (int)(freq / binHz);
    if (bin >= count)
      bin = count - 1;

    float norm = mags[bin];
    if (norm > 1)
      norm = 1;
    if (norm < 0)
      norm = 0;

    unsigned char r, g, b;
    if (norm < 0.25f) {
      r = 0;
      g = 0;
      b = (unsigned char)(norm * 4 * 200);
    } else if (norm < 0.5f) {
      float t = (norm - 0.25f) * 4;
      r = 0;
      g = (unsigned char)(t * 220);
      b = 200;
    } else if (norm < 0.75f) {
      float t = (norm - 0.5f) * 4;
      r = (unsigned char)(t * 220);
      g = 220 + (unsigned char)(t * 35);
      b = (unsigned char)(200 - t * 200);
    } else {
      float t = (norm - 0.75f) * 4;
      r = 220 + (unsigned char)(t * 35);
      g = 255;
      b = 0;
    }

    // FLIP: write to inverted row so low freqs appear at bottom
    int flippedRow = WF_ROWS - 1 - row;
    int idx = flippedRow * bytesPerRow + (WF_COLS - 1) * 3;
    data[idx] = r;
    data[idx + 1] = g;
    data[idx + 2] = b;
  }

  [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithRed:0.02 green:0.02 blue:0.1 alpha:1] setFill];
  NSRectFill(self.bounds);

  CGFloat marginL = 45;
  CGFloat W = self.bounds.size.width - marginL;
  CGFloat H = self.bounds.size.height - 5;
  CGFloat baseY = 5;

  // Draw bitmap scaled to view
  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(WF_COLS, WF_ROWS)];
  [img addRepresentation:_bitmap];
  [img drawInRect:NSMakeRect(marginL, baseY, W, H)
         fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver
         fraction:1.0];

  // Frequency labels
  [[NSColor colorWithWhite:0.5 alpha:0.3] setStroke];
  NSDictionary *la = @{
    NSFontAttributeName : [NSFont systemFontOfSize:10],
    NSForegroundColorAttributeName : [NSColor colorWithWhite:0.6 alpha:1]
  };
  float marks[] = {62, 125, 250, 500, 1000, 2000, 4000, 8000};
  NSString *labels[] = {@"62", @"125", @"250", @"500",
                        @"1K", @"2K",  @"4K",  @"8K"};
  float minLog = log10f(30.0f);
  float maxLog = log10f(12000.0f);
  float rangeLog = maxLog - minLog;
  for (int i = 0; i < 8; i++) {
    float f = marks[i];
    float yN = (log10f(f) - minLog) / rangeLog;
    float y = baseY + yN * H;
    if (y > baseY + 10 && y < baseY + H - 10) {
      NSBezierPath *l = [NSBezierPath bezierPath];
      [l moveToPoint:NSMakePoint(marginL, y)];
      [l lineToPoint:NSMakePoint(self.bounds.size.width, y)];
      [l stroke];
      [labels[i] drawAtPoint:NSMakePoint(5, y - 6) withAttributes:la];
    }
  }

  // Hover
  if (_mouseIn && _mousePos.y > baseY && _mousePos.x > marginL) {
    float yN = (_mousePos.y - baseY) / H;
    float freq = powf(10.0f, yN * rangeLog + minLog);
    [[NSColor orangeColor] setStroke];
    NSBezierPath *hl = [NSBezierPath bezierPath];
    [hl moveToPoint:NSMakePoint(marginL, _mousePos.y)];
    [hl lineToPoint:NSMakePoint(self.bounds.size.width, _mousePos.y)];
    [hl setLineWidth:1.5];
    [hl stroke];
    NSString *fl = (freq >= 1000)
                       ? [NSString stringWithFormat:@"%.2f kHz", freq / 1000]
                       : [NSString stringWithFormat:@"%.1f Hz", freq];
    NSDictionary *ha = @{
      NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
      NSForegroundColorAttributeName : [NSColor orangeColor]
    };
    [[NSColor colorWithWhite:0 alpha:0.8] setFill];
    NSSize sz = [fl sizeWithAttributes:ha];
    NSRectFill(NSMakeRect(_mousePos.x + 8, _mousePos.y + 3, sz.width + 8,
                          sz.height + 2));
    [fl drawAtPoint:NSMakePoint(_mousePos.x + 12, _mousePos.y + 4)
        withAttributes:ha];
  }

  // Draw selection indicator if a column is selected
  if (_selectedCol >= 0 && _selectedCol < WF_COLS) {
    float xNorm = (float)_selectedCol / WF_COLS;
    CGFloat x = marginL + xNorm * W;
    [[NSColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.9] setStroke];
    NSBezierPath *selLine = [NSBezierPath bezierPath];
    [selLine moveToPoint:NSMakePoint(x, baseY)];
    [selLine lineToPoint:NSMakePoint(x, baseY + H)];
    [selLine setLineWidth:2.0];
    [selLine stroke];

    // Draw label at top
    NSDictionary *selAttr = @{
      NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
      NSForegroundColorAttributeName : [NSColor orangeColor]
    };
    NSString *selLabel = @"📍 SELECTED";
    [[NSColor colorWithWhite:0 alpha:0.8] setFill];
    NSSize sz = [selLabel sizeWithAttributes:selAttr];
    CGFloat labelX = MIN(x + 5, self.bounds.size.width - sz.width - 10);
    NSRectFill(
        NSMakeRect(labelX - 2, baseY + H - 20, sz.width + 6, sz.height + 2));
    [selLabel drawAtPoint:NSMakePoint(labelX, baseY + H - 18)
           withAttributes:selAttr];
  }

  if (gPaused) {
    NSDictionary *pa = @{
      NSFontAttributeName : [NSFont boldSystemFontOfSize:20],
      NSForegroundColorAttributeName : [NSColor redColor]
    };
    [@"⏸ PAUSED" drawAtPoint:NSMakePoint(self.bounds.size.width - 130,
                                         self.bounds.size.height - 28)
              withAttributes:pa];
  }
}
@end

@implementation SpectrumView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    memset(_smoothMags, 0, sizeof(_smoothMags));
    memset(_peaks, 0, sizeof(_peaks));
    memset(_snapshotMags, 0, sizeof(_snapshotMags));
    _showingSnapshot = NO;
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                      NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
  }
  return self;
}

- (void)mouseEntered:(NSEvent *)e {
  _mouseIn = YES;
  [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)e {
  _mouseIn = NO;
  [self setNeedsDisplay:YES];
}
- (void)mouseMoved:(NSEvent *)e {
  _mousePos = [self convertPoint:[e locationInWindow] fromView:nil];
  [self setNeedsDisplay:YES];
}

- (void)update:(float *)mags count:(int)count {
  if (gPaused)
    return;
  // Only update live spectrum if not showing a snapshot
  if (!_showingSnapshot) {
    for (int i = 0; i < count && i < FFT_SIZE / 2; i++) {
      _smoothMags[i] = _smoothMags[i] * 0.7f + mags[i] * 0.3f;
      if (_smoothMags[i] > _peaks[i])
        _peaks[i] = _smoothMags[i];
      else
        _peaks[i] *= 0.97f;
    }
    [self setNeedsDisplay:YES];
  }
}

- (void)displaySnapshot:(float *)mags count:(int)count {
  for (int i = 0; i < count && i < FFT_SIZE / 2; i++) {
    _snapshotMags[i] = mags[i];
  }
  _showingSnapshot = YES;
  // Reset peaks for the snapshot
  memcpy(_peaks, _snapshotMags, sizeof(_snapshotMags));
  [self setNeedsDisplay:YES];
}

- (void)clearSnapshot {
  _showingSnapshot = NO;
  memset(_peaks, 0, sizeof(_peaks));
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor colorWithRed:0.02 green:0.02 blue:0.1 alpha:1] setFill];
  NSRectFill(self.bounds);

  CGFloat marginL = 30, marginB = 30, marginT = 5;
  CGFloat W = self.bounds.size.width - marginL;
  CGFloat H = self.bounds.size.height - marginB - marginT;
  CGFloat baseY = marginB;

  float binHz = 44100.0f / FFT_SIZE;
  float minLog = log10f(30.0f);
  float maxLog = log10f(12000.0f);
  float rangeLog = maxLog - minLog;

  // Choose which magnitudes to display
  float *displayMags = _showingSnapshot ? _snapshotMags : _smoothMags;

  // Filled area
  NSBezierPath *fillPath = [NSBezierPath bezierPath];
  [fillPath moveToPoint:NSMakePoint(marginL, baseY)];
  for (int px = 0; px < (int)W; px += 2) {
    float xNorm = (float)px / W;
    float freq = powf(10.0f, xNorm * rangeLog + minLog);
    int bin = (int)(freq / binHz);
    if (bin >= FFT_SIZE / 2)
      bin = FFT_SIZE / 2 - 1;
    float n = displayMags[bin];
    if (n > 1)
      n = 1;
    [fillPath lineToPoint:NSMakePoint(marginL + px, baseY + n * H)];
  }
  [fillPath lineToPoint:NSMakePoint(marginL + W, baseY)];
  [fillPath closePath];
  // Different color for snapshot vs live
  if (_showingSnapshot) {
    [[NSColor colorWithRed:0.8 green:0.4 blue:0.2 alpha:0.6] setFill];
  } else {
    [[NSColor colorWithRed:0.2 green:0.5 blue:0.7 alpha:0.6] setFill];
  }
  [fillPath fill];

  // Line
  if (_showingSnapshot) {
    [[NSColor colorWithRed:1.0 green:0.5 blue:0.2 alpha:1.0] setStroke];
  } else {
    [[NSColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0] setStroke];
  }
  NSBezierPath *linePath = [NSBezierPath bezierPath];
  for (int px = 0; px < (int)W; px += 2) {
    float xNorm = (float)px / W;
    float freq = powf(10.0f, xNorm * rangeLog + minLog);
    int bin = (int)(freq / binHz);
    if (bin >= FFT_SIZE / 2)
      bin = FFT_SIZE / 2 - 1;
    float n = displayMags[bin];
    if (n > 1)
      n = 1;
    if (px == 0)
      [linePath moveToPoint:NSMakePoint(marginL + px, baseY + n * H)];
    else
      [linePath lineToPoint:NSMakePoint(marginL + px, baseY + n * H)];
  }
  [linePath setLineWidth:1.5];
  [linePath stroke];

  // Peak
  [[NSColor colorWithWhite:1.0 alpha:0.7] setStroke];
  NSBezierPath *peakPath = [NSBezierPath bezierPath];
  for (int px = 0; px < (int)W; px += 2) {
    float xNorm = (float)px / W;
    float freq = powf(10.0f, xNorm * rangeLog + minLog);
    int bin = (int)(freq / binHz);
    if (bin >= FFT_SIZE / 2)
      bin = FFT_SIZE / 2 - 1;
    float p = _peaks[bin];
    if (p > 1)
      p = 1;
    if (px == 0)
      [peakPath moveToPoint:NSMakePoint(marginL + px, baseY + p * H)];
    else
      [peakPath lineToPoint:NSMakePoint(marginL + px, baseY + p * H)];
  }
  [peakPath setLineWidth:1.0];
  [peakPath stroke];

  // Labels
  NSDictionary *la = @{
    NSFontAttributeName : [NSFont systemFontOfSize:10],
    NSForegroundColorAttributeName : [NSColor colorWithWhite:0.6 alpha:1]
  };
  float lf[] = {50, 100, 200, 500, 1000, 2000, 5000, 10000};
  for (int i = 0; i < 8; i++) {
    float f = lf[i];
    float xNorm = (log10f(f) - minLog) / rangeLog;
    CGFloat x = marginL + xNorm * W;
    if (x > marginL && x < marginL + W - 20) {
      NSString *l = (f >= 1000) ? [NSString stringWithFormat:@"%.0fk", f / 1000]
                                : [NSString stringWithFormat:@"%.0f", f];
      [l drawAtPoint:NSMakePoint(x - 8, 8) withAttributes:la];
    }
  }
  [@"Hz" drawAtPoint:NSMakePoint(5, 8) withAttributes:la];

  // Hover
  if (_mouseIn && _mousePos.x > marginL && _mousePos.y > marginB) {
    float xNorm = (_mousePos.x - marginL) / W;
    float freq = powf(10.0f, xNorm * rangeLog + minLog);
    [[NSColor orangeColor] setStroke];
    NSBezierPath *vl = [NSBezierPath bezierPath];
    [vl moveToPoint:NSMakePoint(_mousePos.x, baseY)];
    [vl lineToPoint:NSMakePoint(_mousePos.x,
                                self.bounds.size.height - marginT)];
    [vl setLineWidth:1.5];
    [vl stroke];
    NSString *fl = (freq >= 1000)
                       ? [NSString stringWithFormat:@"%.2f kHz", freq / 1000]
                       : [NSString stringWithFormat:@"%.1f Hz", freq];
    NSDictionary *ha = @{
      NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
      NSForegroundColorAttributeName : [NSColor orangeColor]
    };
    [[NSColor colorWithWhite:0 alpha:0.8] setFill];
    NSSize sz = [fl sizeWithAttributes:ha];
    NSRectFill(NSMakeRect(_mousePos.x + 6,
                          MIN(_mousePos.y + 5, self.bounds.size.height - 18),
                          sz.width + 6, sz.height));
    [fl drawAtPoint:NSMakePoint(
                        _mousePos.x + 9,
                        MIN(_mousePos.y + 5, self.bounds.size.height - 18))
        withAttributes:ha];
  }

  // Draw Peak Labels
  // Find top peaks
  struct Peak {
    int bin;
    float mag;
  };
  struct Peak peaks[5];
  int peakCount = 0;

  // Simple peak finding
  for (int i = 5; i < FFT_SIZE / 2 - 5; i++) {
    float m = displayMags[i];
    if (m > 0.3f && m > displayMags[i - 1] && m > displayMags[i + 1]) {
      // Check if it's a local max in a wider window
      bool isMax = true;
      for (int k = -5; k <= 5; k++) {
        if (displayMags[i + k] > m) {
          isMax = false;
          break;
        }
      }

      if (isMax) {
        // Insert into sorted top peaks
        if (peakCount < 5) {
          peaks[peakCount].bin = i;
          peaks[peakCount].mag = m;
          peakCount++;
        } else {
          // Replace smallest if this is bigger
          int minIdx = 0;
          for (int k = 1; k < 5; k++)
            if (peaks[k].mag < peaks[minIdx].mag)
              minIdx = k;

          if (m > peaks[minIdx].mag) {
            peaks[minIdx].bin = i;
            peaks[minIdx].mag = m;
          }
        }
      }
    }
  }

  NSDictionary *pkAttr = @{
    NSFontAttributeName : [NSFont boldSystemFontOfSize:10],
    NSForegroundColorAttributeName : [NSColor whiteColor]
  };

  for (int i = 0; i < peakCount; i++) {
    float f = peaks[i].bin * binHz;
    float xNorm = (log10f(f) - minLog) / rangeLog;
    float x = marginL + xNorm * W;
    float y = baseY + peaks[i].mag * H;

    if (x > marginL && x < marginL + W) {
      NSString *s = (f >= 1000) ? [NSString stringWithFormat:@"%.1fk", f / 1000]
                                : [NSString stringWithFormat:@"%.0f", f];
      [s drawAtPoint:NSMakePoint(x - 10, y + 2) withAttributes:pkAttr];
    }
  }
}
@end

// ========== CONTROL BAR ==========
@interface ControlBar : NSView
@property(strong) NSButton *pauseBtn;
@property(assign) float db, avg, max;
@end

@implementation ControlBar

- (instancetype)initWithFrame:(NSRect)frame
                       target:(id)target
                       action:(SEL)action {
  self = [super initWithFrame:frame];
  if (self) {
    _pauseBtn = [[NSButton alloc] initWithFrame:NSMakeRect(10, 12, 100, 36)];
    [_pauseBtn setTitle:@"⏸ PAUSE"];
    [_pauseBtn setTarget:target];
    [_pauseBtn setAction:action];
    [_pauseBtn setBezelStyle:NSBezelStyleRounded];
    [_pauseBtn setFont:[NSFont boldSystemFontOfSize:13]];
    [_pauseBtn setWantsLayer:YES];
    _pauseBtn.layer.backgroundColor = [[NSColor colorWithRed:1.0
                                                       green:0.5
                                                        blue:0.0
                                                       alpha:1.0] CGColor];
    _pauseBtn.layer.cornerRadius = 6;
    [self addSubview:_pauseBtn];
  }
  return self;
}

- (void)drawRect:(NSRect)r {
  [[NSColor colorWithRed:0.05 green:0.05 blue:0.1 alpha:1] setFill];
  NSRectFill(self.bounds);
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  [[NSColor colorWithWhite:0.15 alpha:1] setFill];
  NSRectFill(NSMakeRect(130, H / 2 - 8, W - 270, 16));
  float n = (self.db - 30) / 80;
  if (n < 0)
    n = 0;
  if (n > 1)
    n = 1;
  [[NSColor cyanColor] setFill];
  NSRectFill(NSMakeRect(130, H / 2 - 8, (W - 270) * n, 16));
  NSDictionary *ba = @{
    NSForegroundColorAttributeName : [NSColor cyanColor],
    NSFontAttributeName : [NSFont boldSystemFontOfSize:18]
  };
  [[NSString stringWithFormat:@"%.1f dB", self.db]
         drawAtPoint:NSMakePoint(130, H / 2 + 12)
      withAttributes:ba];
  NSDictionary *sa = @{
    NSForegroundColorAttributeName : [NSColor grayColor],
    NSFontAttributeName : [NSFont systemFontOfSize:10]
  };
  [[NSString stringWithFormat:@"AVG %.1f  MAX %.1f", self.avg, self.max]
         drawAtPoint:NSMakePoint(W - 130, H / 2 - 2)
      withAttributes:sa];
}
@end

// ========== AUDIO ==========
@interface Audio : NSObject
@property(strong) AVAudioEngine *engine;
@property(copy) void (^onData)
    (float *mags, int count, float db, float avg, float max);
@end

@implementation Audio {
  float _sum;
  int _cnt;
  float _mx;
  FFTSetup _fftSetup;
  float *_window;
  DSPSplitComplex _splitComplex;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _fftSetup = vDSP_create_fftsetup(FFT_LOG2, FFT_RADIX2);
    _window = (float *)malloc(FFT_SIZE * sizeof(float));
    _splitComplex.realp = (float *)malloc(FFT_SIZE / 2 * sizeof(float));
    _splitComplex.imagp = (float *)malloc(FFT_SIZE / 2 * sizeof(float));
    vDSP_hann_window(_window, FFT_SIZE, vDSP_HANN_NORM);
  }
  return self;
}

- (void)dealloc {
  if (_fftSetup)
    vDSP_destroy_fftsetup(_fftSetup);
  free(_window);
  free(_splitComplex.realp);
  free(_splitComplex.imagp);
}

- (void)start {
  self.engine = [[AVAudioEngine alloc] init];
  AVAudioInputNode *in = [self.engine inputNode];
  [in installTapOnBus:0
           bufferSize:FFT_SIZE
               format:[in inputFormatForBus:0]
                block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) {
                  [self process:buf];
                }];
  [self.engine startAndReturnError:nil];
}

- (void)process:(AVAudioPCMBuffer *)buf {
  if (gPaused)
    return;

  float *samples = buf.floatChannelData[0];
  if ((int)buf.frameLength < FFT_SIZE)
    return;

  float rms = 0;
  vDSP_rmsqv(samples, 1, &rms, FFT_SIZE);
  float db = 20 * log10f(rms + 1e-10f) + 94;
  _sum += db;
  _cnt++;
  if (db > _mx)
    _mx = db;
  _mx -= 0.02f;
  float avg = _sum / _cnt;
  if (_cnt > 100) {
    _sum = avg * 50;
    _cnt = 50;
  }

  float *windowed = (float *)malloc(FFT_SIZE * sizeof(float));
  vDSP_vmul(samples, 1, _window, 1, windowed, 1, FFT_SIZE);
  vDSP_ctoz((DSPComplex *)windowed, 2, &_splitComplex, 1, FFT_SIZE / 2);
  vDSP_fft_zrip(_fftSetup, &_splitComplex, 1, FFT_LOG2, FFT_FORWARD);

  float *mags = (float *)malloc(FFT_SIZE / 2 * sizeof(float));
  vDSP_zvmags(&_splitComplex, 1, mags, 1, FFT_SIZE / 2);

  float *normalized = (float *)malloc(FFT_SIZE / 2 * sizeof(float));
  for (int i = 0; i < FFT_SIZE / 2; i++) {
    float amp = sqrtf(mags[i]) / FFT_SIZE;
    float dbVal = 20 * log10f(amp + 1e-10f);
    float norm = (dbVal + 90) / 60.0f;
    if (norm < 0)
      norm = 0;
    if (norm > 1)
      norm = 1;
    normalized[i] = norm;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.onData)
      self.onData(normalized, FFT_SIZE / 2, db, avg, _mx);
    free(normalized);
  });

  free(windowed);
  free(mags);
}
@end

// ========== APP DELEGATE ==========
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *win;
@property(strong) WaterfallView *wf;
@property(strong) SpectrumView *sp;
@property(strong) ControlBar *ctrl;
@property(strong) Audio *audio;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [NSApp activateIgnoringOtherApps:YES];

  self.win = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1000, 900)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [self.win setTitle:@"Spectrogram Analyzer"];
  [self.win setBackgroundColor:[NSColor blackColor]];
  [self.win center];

  NSView *v = self.win.contentView;

  self.ctrl = [[ControlBar alloc] initWithFrame:NSMakeRect(0, 835, 1000, 65)
                                         target:self
                                         action:@selector(togglePause)];
  self.ctrl.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [v addSubview:self.ctrl];

  self.wf = [[WaterfallView alloc] initWithFrame:NSMakeRect(0, 400, 1000, 435)];
  self.wf.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [v addSubview:self.wf];

  self.sp = [[SpectrumView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 400)];
  self.sp.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [v addSubview:self.sp];

  // Connect waterfall to spectrum view for click-to-spectrum feature
  self.wf.spectrumView = self.sp;

  [self.win makeKeyAndOrderFront:nil];

  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                           completionHandler:^(BOOL ok) {
                             if (ok)
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 [self startAudio];
                               });
                           }];
}

- (void)togglePause {
  gPaused = !gPaused;
  self.ctrl.pauseBtn.title = gPaused ? @"▶ RESUME" : @"⏸ PAUSE";
  [self.wf setNeedsDisplay:YES];
}

- (void)startAudio {
  self.audio = [[Audio alloc] init];
  __weak AppDelegate *ws = self;
  self.audio.onData =
      ^(float *mags, int count, float db, float avg, float max) {
        AppDelegate *s = ws;
        if (!s)
          return;
        [s.wf addColumn:mags count:count];
        [s.sp update:mags count:count];
        s.ctrl.db = db;
        s.ctrl.avg = avg;
        s.ctrl.max = max;
        [s.ctrl setNeedsDisplay:YES];
      };
  [self.audio start];
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setDelegate:[[AppDelegate alloc] init]];
    [app run];
  }
  return 0;
}
