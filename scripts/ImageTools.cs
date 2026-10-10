// 由 compare-snapshots.ps1 与 render.ps1 通过 Add-Type 在 PowerShell 进程内编译，依赖 Windows 上 PowerShell 自带的 System.Drawing。
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace WpfOffscreenRender
{
    public sealed class CompareResult
    {
        public int BeforeWidth { get; set; }
        public int BeforeHeight { get; set; }
        public int AfterWidth { get; set; }
        public int AfterHeight { get; set; }
        public long ChangedPixels { get; set; }
        public long TotalPixels { get; set; }
        // 变化区域的外接矩形（像素，基于 after 图）；无变化时为 null。
        public int[] ChangedBounds { get; set; }
    }

    public static class ImageTools
    {
        // 逐像素比较两张 PNG；任一通道差值大于 tolerance 视为变化。尺寸不同时，超出公共区域的部分全部计为变化。
        // 差异图以 after 为底、淡化为浅灰，变化像素标成红色。
        public static CompareResult Compare(string beforePath, string afterPath, string diffPath, int tolerance)
        {
            using (var before = Load(beforePath))
            using (var after = Load(afterPath))
            {
                int width = Math.Max(before.Width, after.Width), height = Math.Max(before.Height, after.Height);
                var a = Pixels(before);
                var b = Pixels(after);
                var diff = new int[width * height];
                long changed = 0;
                int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
                for (var y = 0; y < height; y++)
                {
                    for (var x = 0; x < width; x++)
                    {
                        var inA = x < before.Width && y < before.Height;
                        var inB = x < after.Width && y < after.Height;
                        var pa = inA ? a[y * before.Width + x] : 0;
                        var pb = inB ? b[y * after.Width + x] : 0;
                        if (inA != inB || Differs(pa, pb, tolerance))
                        {
                            changed++;
                            if (x < minX) minX = x;
                            if (y < minY) minY = y;
                            if (x > maxX) maxX = x;
                            if (y > maxY) maxY = y;
                            diff[y * width + x] = unchecked((int)0xFFE0281E);
                        }
                        else
                        {
                            // 灰度淡化：保留轮廓便于定位，不与红色标记混淆。
                            var source = inB ? pb : pa;
                            var gray = (Channel(source, 16) * 30 + Channel(source, 8) * 59 + Channel(source, 0) * 11) / 100;
                            var light = 200 + gray * 55 / 255;
                            diff[y * width + x] = unchecked((int)0xFF000000) | (light << 16) | (light << 8) | light;
                        }
                    }
                }
                Save(diff, width, height, diffPath);
                return new CompareResult
                {
                    BeforeWidth = before.Width, BeforeHeight = before.Height, AfterWidth = after.Width, AfterHeight = after.Height,
                    ChangedPixels = changed, TotalPixels = (long)width * height,
                    ChangedBounds = maxX < 0 ? null : new[] { minX, minY, maxX - minX + 1, maxY - minY + 1 }
                };
            }
        }

        // 把多张截图缩放后拼成一张总览图，每张上方标注文字，便于一次查看多个主题 / 尺寸 / DPI。
        public static void ContactSheet(string[] imagePaths, string[] labels, string outPath, int tileWidth)
        {
            const int padding = 12, labelHeight = 24;
            var columns = Math.Min(imagePaths.Length, imagePaths.Length <= 4 ? 2 : 3);
            var images = new Bitmap[imagePaths.Length];
            try
            {
                var tileHeights = new int[images.Length];
                for (var i = 0; i < images.Length; i++)
                {
                    images[i] = Load(imagePaths[i]);
                    tileHeights[i] = (int)Math.Ceiling(images[i].Height * (double)tileWidth / images[i].Width);
                }
                var rows = (images.Length + columns - 1) / columns;
                var rowHeights = new int[rows];
                for (var i = 0; i < images.Length; i++) rowHeights[i / columns] = Math.Max(rowHeights[i / columns], tileHeights[i]);
                var sheetWidth = padding + columns * (tileWidth + padding);
                var sheetHeight = padding;
                foreach (var rowHeight in rowHeights) sheetHeight += labelHeight + rowHeight + padding;

                using (var sheet = new Bitmap(sheetWidth, sheetHeight, PixelFormat.Format32bppArgb))
                using (var graphics = Graphics.FromImage(sheet))
                using (var font = new Font("Segoe UI", 10f, GraphicsUnit.Point))
                using (var border = new Pen(Color.FromArgb(160, 160, 160)))
                {
                    graphics.Clear(Color.FromArgb(240, 240, 240));
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.SmoothingMode = SmoothingMode.HighQuality;
                    var top = padding;
                    for (var row = 0; row < rows; row++)
                    {
                        for (var column = 0; column < columns; column++)
                        {
                            var i = row * columns + column;
                            if (i >= images.Length) break;
                            var left = padding + column * (tileWidth + padding);
                            graphics.DrawString(labels[i], font, Brushes.Black, left, top + 4);
                            var target = new Rectangle(left, top + labelHeight, tileWidth, tileHeights[i]);
                            graphics.DrawImage(images[i], target);
                            graphics.DrawRectangle(border, target);
                        }
                        top += labelHeight + rowHeights[row] + padding;
                    }
                    sheet.Save(outPath, ImageFormat.Png);
                }
            }
            finally
            {
                foreach (var image in images) image?.Dispose();
            }
        }

        private static int Channel(int pixel, int shift) => (pixel >> shift) & 0xFF;

        private static bool Differs(int a, int b, int tolerance)
        {
            for (var shift = 0; shift <= 24; shift += 8)
                if (Math.Abs(Channel(a, shift) - Channel(b, shift)) > tolerance) return true;
            return false;
        }

        // 复制到内存后立即释放文件，避免 GDI+ 锁住 PNG。
        private static Bitmap Load(string path)
        {
            using (var source = new Bitmap(path)) return new Bitmap(source);
        }

        private static int[] Pixels(Bitmap bitmap)
        {
            var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var pixels = new int[bitmap.Width * bitmap.Height];
                for (var y = 0; y < bitmap.Height; y++)
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), pixels, y * bitmap.Width, bitmap.Width);
                return pixels;
            }
            finally { bitmap.UnlockBits(data); }
        }

        private static void Save(int[] pixels, int width, int height, string path)
        {
            using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
            {
                var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                try
                {
                    for (var y = 0; y < height; y++)
                        Marshal.Copy(pixels, y * width, IntPtr.Add(data.Scan0, y * data.Stride), width);
                }
                finally { bitmap.UnlockBits(data); }
                bitmap.Save(path, ImageFormat.Png);
            }
        }
    }
}
