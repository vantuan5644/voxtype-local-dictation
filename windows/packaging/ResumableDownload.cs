using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Threading;

internal enum DownloadPhase { Downloading, Resuming, Verifying }

internal delegate void DownloadProgressHandler(DownloadPhase phase, long received, long total);

// The one HTTPS downloader in the Windows package. voxtype-configure.exe uses it for the
// multi-gigabyte models and VoxTypeSetup.exe for the release description and the MSIX, so
// both build scripts compile this file next to their launcher.
//
// Bytes land in <Destination>.partial. With Sha256 set, Destination appears only after the
// partial matches that digest; a mismatch deletes the partial.
//
// Recovery, each case seen or reproduced on a real install:
// - An existing partial resumes with a Range request. A server that ignores the range (200)
//   or answers a different one restarts the file from zero.
// - A partial that already holds every byte is verified instead of requested again: by size
//   when the catalog pins one, otherwise when the server answers 416. Closing setup while it
//   hashed a finished download used to leave every later attempt asking for bytes past the
//   end and failing with 416. A match is finalized; a mismatch is deleted and downloaded
//   once more from the start.
// - No new bytes for StallTimeoutMilliseconds aborts the request and resumes from the
//   partial. Only MaximumAttemptsWithoutProgress consecutive attempts that add nothing fail
//   the download, and the partial stays for the next try.
internal sealed class ResumableDownload
{
    public string Url;
    public string Destination;
    public string Sha256;
    public long ExpectedSize { get; set; }
    public string UserAgent = "VoxType-Windows-Setup";
    public int StallTimeoutMilliseconds = 60000;
    public int MaximumAttemptsWithoutProgress = 5;
    public int RetryDelayMilliseconds = 2000;
    public DownloadProgressHandler Progress;

    private const int BufferSize = 81920;
    private const int ReportIntervalMilliseconds = 250;
    private int lastReport;
    private long lastTotal;

    private enum Outcome { Complete, RangeNotSatisfiable, Interrupted }

    public string PartialPath { get { return Destination + ".partial"; } }

    public void Run()
    {
        if (String.IsNullOrEmpty(Url) || String.IsNullOrEmpty(Destination))
            throw new InvalidOperationException("A download needs a URL and a destination.");
        // csc emits no TargetFrameworkAttribute, so .NET Framework runs the launchers with
        // 4.0 defaults that offer only SSL 3.0 and TLS 1.0. GitHub, Hugging Face and its CDN
        // refuse both ("Could not create SSL/TLS secure channel"). SystemDefault is rejected
        // in that mode, so TLS 1.2 is named explicitly, for this process only.
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        var partial = PartialPath;
        var restarted = false;
        var attemptsWithoutProgress = 0;
        lastTotal = ExpectedSize;
        while (true)
        {
            var existing = File.Exists(partial) ? new FileInfo(partial).Length : 0L;
            if (ExpectedSize > 0 && existing > ExpectedSize)
            {
                File.Delete(partial);
                existing = 0;
            }
            if (ExpectedSize > 0 && existing == ExpectedSize)
            {
                if (Finish(partial, existing, !restarted)) return;
                restarted = true;
                continue;
            }

            bool progressed;
            var outcome = Attempt(partial, existing, out progressed);
            if (outcome == Outcome.Complete)
            {
                // Bytes fetched in this run that fail the digest are an error, as before.
                Finish(partial, new FileInfo(partial).Length, false);
                return;
            }
            if (outcome == Outcome.RangeNotSatisfiable)
            {
                // The partial already holds at least the whole file: check it instead of
                // asking for more. Without a digest, a partial left by an earlier run cannot
                // be trusted, so it is fetched again from the start.
                if (Sha256 == null && !restarted) File.Delete(partial);
                else if (Finish(partial, existing, !restarted)) return;
                restarted = true;
                continue;
            }

            if (progressed) attemptsWithoutProgress = 0;
            else attemptsWithoutProgress++;
            if (attemptsWithoutProgress >= MaximumAttemptsWithoutProgress)
                throw new IOException("The download of " + Name + " stopped making progress. " +
                    "The part already downloaded is kept, so trying again resumes it.");
            var kept = File.Exists(partial) ? new FileInfo(partial).Length : 0L;
            Report(DownloadPhase.Resuming, kept, lastTotal, true);
            if (!progressed) Thread.Sleep(RetryDelayMilliseconds * attemptsWithoutProgress);
        }
    }

    private string Name { get { return Path.GetFileName(Destination); } }

    // Verifies a partial that should hold the whole file and moves it to Destination.
    // Returns false after deleting a mismatched partial when another attempt is allowed.
    private bool Finish(string partial, long length, bool allowRestart)
    {
        if (Sha256 != null)
        {
            Report(DownloadPhase.Verifying, length, length, true);
            if (!HashMatches(partial, Sha256))
            {
                File.Delete(partial);
                if (allowRestart) return false;
                throw new InvalidDataException(Name + " failed its SHA-256 check.");
            }
        }
        if (File.Exists(Destination)) File.Delete(Destination);
        File.Move(partial, Destination);
        return true;
    }

    private Outcome Attempt(string partial, long existing, out bool progressed)
    {
        progressed = false;
        var request = (HttpWebRequest)WebRequest.Create(Url);
        request.UserAgent = UserAgent;
        request.Timeout = StallTimeoutMilliseconds;
        request.ReadWriteTimeout = StallTimeoutMilliseconds;
        if (existing > 0) request.AddRange(existing);
        using (var watchdog = new StallWatchdog(request, StallTimeoutMilliseconds))
        {
            HttpWebResponse response;
            try
            {
                response = (HttpWebResponse)request.GetResponse();
            }
            catch (WebException exception)
            {
                var failed = exception.Response as HttpWebResponse;
                if (failed != null)
                {
                    var code = (int)failed.StatusCode;
                    failed.Close();
                    if (code == 416 && existing > 0) return Outcome.RangeNotSatisfiable;
                    if (code == 408 || code == 429 || code >= 500) return Outcome.Interrupted;
                    throw;
                }
                if (IsInterruption(exception)) return Outcome.Interrupted;
                throw;
            }
            using (response)
            {
                var append = false;
                if (existing > 0 && response.StatusCode == HttpStatusCode.PartialContent)
                {
                    if (RangeStart(response) != existing)
                    {
                        // A different range than requested cannot be appended; start over.
                        File.Delete(partial);
                        return Outcome.Interrupted;
                    }
                    append = true;
                }
                else if (response.StatusCode != HttpStatusCode.OK &&
                    response.StatusCode != HttpStatusCode.PartialContent)
                {
                    throw new InvalidDataException("The server answered " +
                        (int)response.StatusCode + " for " + Name + ".");
                }
                if (!append) existing = 0;
                var total = ExpectedSize > 0 ? ExpectedSize :
                    response.ContentLength >= 0 ? existing + response.ContentLength : 0L;
                if (total > 0) lastTotal = total;
                var received = existing;
                Report(DownloadPhase.Downloading, received, total, true);
                using (var input = response.GetResponseStream())
                using (var output = new FileStream(partial, append ? FileMode.Append : FileMode.Create,
                    FileAccess.Write, FileShare.None, BufferSize))
                {
                    var buffer = new byte[BufferSize];
                    while (true)
                    {
                        int read;
                        try
                        {
                            read = input.Read(buffer, 0, buffer.Length);
                        }
                        catch (IOException) { return Outcome.Interrupted; }
                        catch (ObjectDisposedException)
                        {
                            if (watchdog.Fired) return Outcome.Interrupted;
                            throw;
                        }
                        catch (WebException exception)
                        {
                            if (IsInterruption(exception)) return Outcome.Interrupted;
                            throw;
                        }
                        if (read == 0) break;
                        output.Write(buffer, 0, read);
                        received += read;
                        progressed = true;
                        watchdog.Touch();
                        Report(DownloadPhase.Downloading, received, total, false);
                    }
                }
                Report(DownloadPhase.Downloading, received, total, true);
                // A connection closed before the announced length is an interruption.
                return total > 0 && received < total ? Outcome.Interrupted : Outcome.Complete;
            }
        }
    }

    private static long RangeStart(HttpWebResponse response)
    {
        // Content-Range: bytes <start>-<end>/<length>
        var value = response.Headers["Content-Range"];
        if (String.IsNullOrEmpty(value)) return -1;
        value = value.Trim();
        if (!value.StartsWith("bytes ", StringComparison.OrdinalIgnoreCase)) return -1;
        var dash = value.IndexOf('-');
        long start;
        if (dash < 7 || !Int64.TryParse(value.Substring(6, dash - 6).Trim(), NumberStyles.None,
                CultureInfo.InvariantCulture, out start))
            return -1;
        return start;
    }

    private static bool IsInterruption(WebException exception)
    {
        switch (exception.Status)
        {
            case WebExceptionStatus.Timeout:
            case WebExceptionStatus.RequestCanceled:
            case WebExceptionStatus.ConnectionClosed:
            case WebExceptionStatus.ReceiveFailure:
            case WebExceptionStatus.SendFailure:
            case WebExceptionStatus.KeepAliveFailure:
            case WebExceptionStatus.PipelineFailure:
            case WebExceptionStatus.ConnectFailure:
            case WebExceptionStatus.NameResolutionFailure:
                return true;
            default:
                return false;
        }
    }

    private void Report(DownloadPhase phase, long received, long total, bool force)
    {
        var handler = Progress;
        if (handler == null) return;
        var now = Environment.TickCount;
        if (!force && unchecked(now - lastReport) < ReportIntervalMilliseconds) return;
        lastReport = now;
        handler(phase, received, total);
    }

    internal static bool HashMatches(string path, string expected)
    {
        string actual;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            1 << 20))
        using (var sha = SHA256.Create())
            actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        return String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
    }

    // Decimal units, matching the sizes quoted in the setup window ("2.5 GB download").
    internal static string FormatBytes(long bytes)
    {
        if (bytes >= 1000000000L)
            return (bytes / 1e9).ToString("0.00", CultureInfo.CurrentCulture) + " GB";
        return (bytes / 1e6).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
    }

    // "1.2 MB of 2.33 GB (5%)", or only the received size when the length is unknown.
    internal static string Describe(long received, long total)
    {
        if (total <= 0) return FormatBytes(received);
        var percent = (int)(Math.Min(received, total) * 100 / total);
        return FormatBytes(received) + " of " + FormatBytes(total) + " (" + percent + "%)";
    }

    // Aborts the request when no byte has arrived for the timeout. This covers connecting,
    // TLS, redirects, headers and the body alike; Abort makes the blocked call throw.
    private sealed class StallWatchdog : IDisposable
    {
        private readonly HttpWebRequest request;
        private readonly int timeout;
        private readonly Timer timer;
        private int lastActivity;
        private int fired;

        public StallWatchdog(HttpWebRequest request, int timeout)
        {
            this.request = request;
            this.timeout = timeout;
            lastActivity = Environment.TickCount;
            var period = Math.Max(50, Math.Min(1000, timeout / 4));
            timer = new Timer(Check, null, period, period);
        }

        public bool Fired { get { return Thread.VolatileRead(ref fired) != 0; } }

        public void Touch() { Interlocked.Exchange(ref lastActivity, Environment.TickCount); }

        private void Check(object state)
        {
            if (unchecked(Environment.TickCount - Thread.VolatileRead(ref lastActivity)) < timeout)
                return;
            if (Interlocked.Exchange(ref fired, 1) != 0) return;
            try { request.Abort(); } catch { }
        }

        public void Dispose() { timer.Dispose(); }
    }
}
