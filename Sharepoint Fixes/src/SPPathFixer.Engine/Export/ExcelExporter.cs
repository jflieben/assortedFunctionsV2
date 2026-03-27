using ClosedXML.Excel;
using SPPathFixer.Engine.Models;
using System.Text;

namespace SPPathFixer.Engine.Export;

public sealed class ExcelExporter
{
    public byte[] Export(List<LongPathItem> items, ScanInfo scan)
    {
        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add("Long Paths");

        // Header
        var headers = new[] { "Delta", "Path Total", "Path Parent", "Leaf Length", "Site URL",
            "Full URL", "Item Name", "Extension", "Type", "Max Allowed",
            "Deepest Child", "Fix Status", "Fix Strategy", "Fix New Name", "Fix Result" };

        for (int i = 0; i < headers.Length; i++)
        {
            ws.Cell(1, i + 1).Value = headers[i];
            ws.Cell(1, i + 1).Style.Font.Bold = true;
            ws.Cell(1, i + 1).Style.Fill.BackgroundColor = XLColor.DarkBlue;
            ws.Cell(1, i + 1).Style.Font.FontColor = XLColor.White;
        }

        // Data
        for (int row = 0; row < items.Count; row++)
        {
            var item = items[row];
            var r = row + 2;
            ws.Cell(r, 1).Value = item.Delta;
            ws.Cell(r, 2).Value = item.PathTotalLength;
            ws.Cell(r, 3).Value = item.PathParentLength;
            ws.Cell(r, 4).Value = item.PathLeafLength;
            ws.Cell(r, 5).Value = item.SiteUrl;
            ws.Cell(r, 6).Value = item.FullUrl;
            ws.Cell(r, 7).Value = item.ItemName;
            ws.Cell(r, 8).Value = item.ItemExtension;
            ws.Cell(r, 9).Value = item.ItemType;
            ws.Cell(r, 10).Value = item.MaxAllowed;
            ws.Cell(r, 11).Value = item.DeepestChildDepth;
            ws.Cell(r, 12).Value = item.FixStatus;
            ws.Cell(r, 13).Value = item.FixStrategy ?? "";
            ws.Cell(r, 14).Value = item.FixNewName ?? "";
            ws.Cell(r, 15).Value = item.FixResult ?? "";

            // Color code delta
            if (item.Delta < -50)
            {
                ws.Cell(r, 1).Style.Font.FontColor = XLColor.Red;
                ws.Cell(r, 1).Style.Font.Bold = true;
            }
            else if (item.Delta < 0)
            {
                ws.Cell(r, 1).Style.Font.FontColor = XLColor.Orange;
            }
        }

        ws.Columns().AdjustToContents(1, 100);

        // Summary sheet
        var summary = workbook.Worksheets.Add("Summary");
        summary.Cell(1, 1).Value = "Scan ID";
        summary.Cell(1, 2).Value = scan.Id;
        summary.Cell(2, 1).Value = "Started";
        summary.Cell(2, 2).Value = scan.StartedAt;
        summary.Cell(3, 1).Value = "Completed";
        summary.Cell(3, 2).Value = scan.CompletedAt ?? "N/A";
        summary.Cell(4, 1).Value = "Max Path Length";
        summary.Cell(4, 2).Value = scan.MaxPathLength;
        summary.Cell(5, 1).Value = "Total Sites";
        summary.Cell(5, 2).Value = scan.TotalSites;
        summary.Cell(6, 1).Value = "Total Libraries";
        summary.Cell(6, 2).Value = scan.TotalLibraries;
        summary.Cell(7, 1).Value = "Total Items Scanned";
        summary.Cell(7, 2).Value = scan.TotalItemsScanned;
        summary.Cell(8, 1).Value = "Long Path Items";
        summary.Cell(8, 2).Value = scan.TotalLongPaths;
        summary.Column(1).Style.Font.Bold = true;
        summary.Columns().AdjustToContents();

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }

    public byte[] ExportCsv(List<LongPathItem> items)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Delta,PathTotal,PathParent,LeafLength,SiteURL,FullURL,ItemName,Extension,Type,MaxAllowed,DeepestChild,FixStatus,FixStrategy,FixNewName,FixResult");

        foreach (var item in items)
        {
            sb.AppendLine($"{item.Delta},{item.PathTotalLength},{item.PathParentLength},{item.PathLeafLength}," +
                $"\"{Esc(item.SiteUrl)}\",\"{Esc(item.FullUrl)}\",\"{Esc(item.ItemName)}\",\"{Esc(item.ItemExtension)}\"," +
                $"{item.ItemType},{item.MaxAllowed},{item.DeepestChildDepth},{item.FixStatus}," +
                $"\"{Esc(item.FixStrategy ?? "")}\",\"{Esc(item.FixNewName ?? "")}\",\"{Esc(item.FixResult ?? "")}\"");
        }

        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    private static string Esc(string s) => s.Replace("\"", "\"\"");
}
