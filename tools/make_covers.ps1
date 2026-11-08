param([string]$List, [string]$One, [string]$Out, [switch]$Crop, [switch]$Preview)
# Pictures -> .sc2 covers for the menu: a SCREEN 2 picture (256x192, 15 colours, two in
# each row of 8 pixels), saved the way BSAVE "X.SC2",0,&H37FF,S does (see MENU_COVER_* in
# ../defines.h), so BLOAD"X.SC2",S shows it too. The picture is fitted in with black round it,
# and Floyd-Steinberg dithered.
#
# Needs Windows PowerShell 5.1 (powershell.exe), which has System.Drawing:
#   powershell -ExecutionPolicy Bypass -File make_covers.ps1 -List covers.txt
#       covers.txt (from organise_sd.py) has lines "crop|picture|Game.sc2" or
#       "crop|picture|Game.sc2|preview.png". crop 1 means the picture may be a whole cassette
#       inlay, and if it is much wider than high the front (the right hand panel) is cut out.
#   powershell -ExecutionPolicy Bypass -File make_covers.ps1 -One cover.jpg -Out Game.sc2 [-Crop] [-Preview]
#       for one cover, eg. to put in a better picture by hand. -Preview also writes Game.png.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging;
public static class Sc2 {
  // Colours 1-15 (0 is see-through), half way between how an MSX1 (TMS9918, as openMSX has it)
  // and an MSX2 (V9938, 3 bits each) show them
  static readonly int[,] Tms = { {0,0,0},{0,0,0},{10,173,30},{52,200,76},{43,45,227},{81,75,251},
    {189,41,37},{30,226,239},{251,44,43},{255,95,76},{189,162,43},{215,180,84},{10,140,24},
    {175,50,154},{178,178,178},{255,255,255} };
  static readonly int[,] V9938 = { {0,0,0},{0,0,0},{1,6,1},{3,7,3},{1,1,7},{2,3,7},{5,1,1},{2,6,7},
    {7,1,1},{7,3,3},{6,6,1},{6,6,4},{1,4,1},{6,2,5},{5,5,5},{7,7,7} };
  static readonly float[,] Pal = new float[16, 3];
  static Sc2() {
    for (int c = 0; c < 16; c++) for (int k = 0; k < 3; k++) Pal[c, k] = (Tms[c, k] + V9938[c, k] * 255f / 7) / 2;
  }
  static float Dist(float r, float g, float b, int c) {
    float dr = r - Pal[c, 0], dg = g - Pal[c, 1], db = b - Pal[c, 2];
    return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
  }
  static float Clamp(float v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
  // The front of a cassette inlay is about 65mm wide and 100mm high
  const double FrontAspect = 0.66;

  public static byte[] Convert(string path, bool crop, string png) {
    var a = new float[192, 256, 3];
    using (var src = new Bitmap(path)) using (var dst = new Bitmap(256, 192, PixelFormat.Format24bppRgb)) {
      Rectangle r = new Rectangle(0, 0, src.Width, src.Height);
      if (crop && src.Width > src.Height * 1.3) {
        int w = (int)(src.Height * FrontAspect);
        r = new Rectangle(src.Width - w, 0, w, src.Height);
      }
      using (var g = Graphics.FromImage(dst)) using (var wrap = new ImageAttributes()) {
        g.Clear(Color.Black);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        wrap.SetWrapMode(WrapMode.TileFlipXY);		// no dark edge from outside the picture
        double s = Math.Min(256.0 / r.Width, 192.0 / r.Height);
        int dw = (int)Math.Round(r.Width * s), dh = (int)Math.Round(r.Height * s);
        g.DrawImage(src, new Rectangle((256 - dw) / 2, (192 - dh) / 2, dw, dh), r.X, r.Y, r.Width, r.Height, GraphicsUnit.Pixel, wrap);
      }
      for (int y = 0; y < 192; y++) for (int x = 0; x < 256; x++) {
        var c = dst.GetPixel(x, y); a[y, x, 0] = c.R; a[y, x, 1] = c.G; a[y, x, 2] = c.B;
      }
    }
    // VRAM 0x0000-0x37FF: patterns, names (0-255 in each third), sprites off, colours
    var vram = new byte[0x3800];
    for (int i = 0; i < 768; i++) vram[0x1800 + i] = (byte)i;
    vram[0x1B00] = 0xD0;
    var v = new float[3];
    for (int y = 0; y < 192; y++) for (int bx = 0; bx < 32; bx++) {
      int x0 = bx * 8;
      // the two colours that do best over these 8 pixels, the error carried along as it goes
      int bestA = 1, bestB = 1; float bestE = float.MaxValue;
      for (int ca = 1; ca < 16; ca++) for (int cb = ca; cb < 16; cb++) {
        float e = 0, er = 0, eg = 0, eb = 0;
        for (int k = 0; k < 8 && e < bestE; k++) {
          float r = Clamp(a[y, x0 + k, 0] + er), gg = Clamp(a[y, x0 + k, 1] + eg), b = Clamp(a[y, x0 + k, 2] + eb);
          float da = Dist(r, gg, b, ca), db = Dist(r, gg, b, cb);
          int c = da <= db ? ca : cb;
          e += Math.Min(da, db);
          er = (r - Pal[c, 0]) * 7 / 16; eg = (gg - Pal[c, 1]) * 7 / 16; eb = (b - Pal[c, 2]) * 7 / 16;
        }
        if (e < bestE) { bestE = e; bestA = ca; bestB = cb; }
      }
      // then do it, spreading the error to the right and below
      byte bits = 0;
      for (int k = 0; k < 8; k++) {
        int x = x0 + k;
        for (int ch = 0; ch < 3; ch++) v[ch] = Clamp(a[y, x, ch]);
        int c = Dist(v[0], v[1], v[2], bestA) <= Dist(v[0], v[1], v[2], bestB) ? bestA : bestB;
        if (c != bestA) bits |= (byte)(0x80 >> k);
        for (int ch = 0; ch < 3; ch++) {
          float e = v[ch] - Pal[c, ch];
          if (x + 1 < 256) a[y, x + 1, ch] += e * 7 / 16;
          if (y + 1 < 192) {
            if (x > 0) a[y + 1, x - 1, ch] += e * 3 / 16;
            a[y + 1, x, ch] += e * 5 / 16;
            if (x + 1 < 256) a[y + 1, x + 1, ch] += e / 16;
          }
        }
      }
      int addr = (y / 8) * 256 + x0 + (y % 8);
      vram[addr] = bits;
      vram[0x2000 + addr] = (byte)((bestB << 4) | bestA);
    }
    if (!string.IsNullOrEmpty(png)) {		// PowerShell passes "" for `$null
      using (var p = new Bitmap(256, 192)) {
        for (int y = 0; y < 192; y++) for (int x = 0; x < 256; x++) {
          int addr = (y / 8) * 256 + (x / 8) * 8 + (y % 8);
          int col = vram[0x2000 + addr];
          int c = (vram[addr] & (0x80 >> (x % 8))) != 0 ? col >> 4 : col & 15;
          p.SetPixel(x, y, Color.FromArgb((int)Pal[c, 0], (int)Pal[c, 1], (int)Pal[c, 2]));
        }
        p.Save(png, ImageFormat.Png);
      }
    }
    var file = new byte[7 + vram.Length];
    file[0] = 0xFE; file[3] = 0xFF; file[4] = 0x37;		// start 0, end 0x37FF, run 0
    Array.Copy(vram, 0, file, 7, vram.Length);
    return file;
  }
}
"@

if ($One) {
  $png = $null; if ($Preview) { $png = [IO.Path]::ChangeExtension($Out, ".png") }
  [IO.File]::WriteAllBytes($Out, [Sc2]::Convert($One, [bool]$Crop, $png))
  exit 0
}
$ok = 0; $bad = 0
foreach ($line in [IO.File]::ReadAllLines($List)) {
  if (-not $line) { continue }
  $p = $line.Split('|')
  try {
    $png = $null; if ($p.Count -gt 3) { $png = $p[3] }
    [IO.File]::WriteAllBytes($p[2], [Sc2]::Convert($p[1], $p[0] -eq '1', $png))
    $ok++
  } catch {
    Write-Output "failed: $($p[1]): $($_.Exception.Message)"
    $bad++
  }
}
Write-Output "covers made $ok, failed $bad"
