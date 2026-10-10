using System.Diagnostics;
using System.Text.Json;

namespace WpfRenderMcp;

// 通过 mcp/invoke-script.ps1 在独立 pwsh 进程中运行 scripts/ 下的脚本。
// 子进程的 stdin / stdout / stderr 全部重定向，不能占用 MCP 的 stdio 通道。
public sealed class ScriptRunner(string root)
{
    public string Root { get; } = root;

    public sealed record Result(string[] Output, int ExitCode, string? Error, string StandardError);

    public async Task<Result> RunAsync(string relativeScript, Dictionary<string, object?> arguments, TimeSpan timeout,
        CancellationToken cancellationToken, bool captureHost = false)
    {
        var work = Path.Combine(Path.GetTempPath(), "wpf-render-mcp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            var argsFile = Path.Combine(work, "args.json");
            var resultFile = Path.Combine(work, "result.json");
            // null 参数不传，交给脚本的默认值。
            var present = arguments.Where(pair => pair.Value is not null).ToDictionary(pair => pair.Key, pair => pair.Value);
            await File.WriteAllTextAsync(argsFile, JsonSerializer.Serialize(present), cancellationToken);

            var startInfo = new ProcessStartInfo("pwsh")
            {
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                // 与服务器相同的工作目录（代理会话的项目目录）：相对路径与向上查找 wpf-render.json 在各工具中含义一致。
                WorkingDirectory = Environment.CurrentDirectory,
            };
            // -ExecutionPolicy Bypass 只作用于这个进程：从 ZIP 解压（带“来自网络”标记）或策略为 AllSigned 时脚本也能运行。
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(Root, "mcp", "invoke-script.ps1"),
                         "-Script", Path.Combine(Root, relativeScript), "-ArgsFile", argsFile, "-ResultFile", resultFile })
                startInfo.ArgumentList.Add(argument);
            if (captureHost) startInfo.ArgumentList.Add("-CaptureHost");

            using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("无法启动 pwsh。");
            process.StandardInput.Close();
            var stdout = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            try { await process.WaitForExitAsync(timeoutSource.Token); }
            catch (OperationCanceledException)
            {
                // 进程树中可能有已退出或无权终止的进程：终止失败不能掩盖超时结论。
                try { process.Kill(entireProcessTree: true); }
                catch (Exception ex) when (ex is InvalidOperationException or AggregateException or System.ComponentModel.Win32Exception) { }
                if (cancellationToken.IsCancellationRequested) throw;
                return new Result([], 1, $"脚本超过 {timeout.TotalSeconds:0} 秒未完成，已终止。", await stderr);
            }
            await stdout;
            var errorText = await stderr;
            if (!File.Exists(resultFile))
                return new Result([], process.ExitCode == 0 ? 1 : process.ExitCode, "脚本没有写出结果文件。", errorText);
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(resultFile, cancellationToken));
            var resultRoot = document.RootElement;
            var output = resultRoot.TryGetProperty("output", out var outputElement) && outputElement.ValueKind == JsonValueKind.Array
                ? outputElement.EnumerateArray().Select(item => item.ToString()).ToArray()
                : outputElement.ValueKind == JsonValueKind.String ? [outputElement.GetString()!] : [];
            var exitCode = resultRoot.TryGetProperty("exitCode", out var code) && code.ValueKind == JsonValueKind.Number ? code.GetInt32() : 0;
            var error = resultRoot.TryGetProperty("error", out var errorElement) && errorElement.ValueKind == JsonValueKind.String ? errorElement.GetString() : null;
            return new Result(output, exitCode, error, errorText);
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
