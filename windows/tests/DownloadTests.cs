using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

// Offline checks for packaging/ResumableDownload.cs against a scripted loopback HTTP server.
// test-windows.ps1 compiles this file together with the downloader and requires exit code 0.
// Each case scripts what the server does per request and records the Range it was asked for
// (-1 for none), so the assertions cover what was requested as well as what was written.
internal static class DownloadTests
{
    private static readonly byte[] Body = CreateBody(300000, 1);
    private static readonly string BodySha = Sha(Body);
    private static string root;
    private static int failures;

    private static int Main()
    {
        // Loopback only; a machine proxy must not change the result.
        WebRequest.DefaultWebProxy = null;
        root = Path.Combine(Path.GetTempPath(),
            "voxtype-download-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Run("fresh download reports progress and verifies", FreshDownload);
            Run("partial resumes with a Range request", ResumesPartial);
            Run("complete partial of pinned size is verified without a request", CompleteKnownSize);
            Run("complete partial of unknown size is verified after 416", CompleteAfter416);
            Run("corrupt complete partial of pinned size restarts", CorruptKnownSize);
            Run("corrupt complete partial restarts after 416", CorruptAfter416);
            Run("partial longer than the pinned size restarts", OversizedPartial);
            Run("stalled connection resumes from the partial", StallResumes);
            Run("connection closed early resumes from the partial", EarlyCloseResumes);
            Run("server ignoring the range rewrites the file", IgnoredRange);
            Run("server answering another range restarts", WrongRange);
            Run("server error is retried", ServerErrorRetried);
            Run("missing file fails without retrying", NotFoundFails);
            Run("digest mismatch deletes the partial", DigestMismatch);
            Run("attempts without progress fail and keep the partial", StallsGiveUp);
            Run("without a digest a 416 partial is fetched again", NoDigestAfter416);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
        Console.WriteLine(failures == 0 ? "Download tests passed." :
            failures + " download test(s) failed.");
        return failures == 0 ? 0 : 1;
    }

    private static void FreshDownload()
    {
        using (var c = new Case("fresh", x => x.FromRange()))
        {
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("-1");
            c.AssertEvent("Downloading:300000/300000");
            c.AssertEvent("Verifying:300000/300000");
        }
    }

    private static void ResumesPartial()
    {
        using (var c = new Case("resume", x => x.FromRange()))
        {
            c.WritePartial(Slice(Body, 0, 100000));
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("100000");
            c.AssertEvent("Downloading:100000/300000");
        }
    }

    private static void CompleteKnownSize()
    {
        using (var c = new Case("complete-known", x => x.FromRange()))
        {
            c.WritePartial(Body);
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("");
        }
    }

    private static void CompleteAfter416()
    {
        using (var c = new Case("complete-416", x => x.FromRange()))
        {
            c.WritePartial(Body);
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("300000");
        }
    }

    private static void CorruptKnownSize()
    {
        using (var c = new Case("corrupt-known", x => x.FromRange()))
        {
            c.WritePartial(Corrupt(Body));
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("-1");
        }
    }

    private static void CorruptAfter416()
    {
        using (var c = new Case("corrupt-416", x => x.FromRange()))
        {
            c.WritePartial(Corrupt(Body));
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("300000,-1");
        }
    }

    private static void OversizedPartial()
    {
        using (var c = new Case("oversized", x => x.FromRange()))
        {
            var longer = new byte[Body.Length + 10];
            Buffer.BlockCopy(Body, 0, longer, 0, Body.Length);
            c.WritePartial(longer);
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("-1");
        }
    }

    private static void StallResumes()
    {
        using (var c = new Case("stall", x =>
        {
            if (x.Index == 0) x.Stall(100000, 10000);
            else x.FromRange();
        }))
        {
            var watch = Stopwatch.StartNew();
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("-1,100000");
            c.AssertEvent("Resuming:100000/300000");
            if (watch.ElapsedMilliseconds > 8000)
                throw new Exception("stall recovery took " + watch.ElapsedMilliseconds + " ms");
        }
    }

    private static void EarlyCloseResumes()
    {
        using (var c = new Case("early-close", x =>
        {
            if (x.Index == 0) x.Truncate(50000);
            else x.FromRange();
        }))
        {
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("-1,50000");
        }
    }

    private static void IgnoredRange()
    {
        using (var c = new Case("ignored-range", x => x.Full()))
        {
            c.WritePartial(CreateBody(1000, 2));
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("1000");
        }
    }

    private static void WrongRange()
    {
        using (var c = new Case("wrong-range", x =>
        {
            if (x.Index == 0) x.PartialFrom(0);
            else x.FromRange();
        }))
        {
            c.WritePartial(Slice(Body, 0, 1000));
            c.Download(BodySha, Body.Length).Run();
            c.AssertFinal();
            c.AssertRanges("1000,-1");
        }
    }

    private static void ServerErrorRetried()
    {
        using (var c = new Case("server-error", x =>
        {
            if (x.Index == 0) x.Head("503 Service Unavailable", 0, null);
            else x.FromRange();
        }))
        {
            c.Download(BodySha, 0).Run();
            c.AssertFinal();
            c.AssertRanges("-1,-1");
        }
    }

    private static void NotFoundFails()
    {
        using (var c = new Case("not-found", x => x.Head("404 Not Found", 0, null)))
        {
            ExpectFailure<WebException>(c.Download(BodySha, 0));
            c.AssertRanges("-1");
            c.AssertNoFiles();
        }
    }

    private static void DigestMismatch()
    {
        using (var c = new Case("mismatch", x => x.FromRange()))
        {
            ExpectFailure<InvalidDataException>(c.Download(Sha(Corrupt(Body)), 0));
            c.AssertRanges("-1");
            c.AssertNoFiles();
        }
    }

    private static void StallsGiveUp()
    {
        using (var c = new Case("give-up", x => x.Stall(0, 10000)))
        {
            c.WritePartial(Slice(Body, 0, 1000));
            var download = c.Download(BodySha, Body.Length);
            download.MaximumAttemptsWithoutProgress = 2;
            ExpectFailure<IOException>(download);
            c.AssertRanges("1000,1000");
            var kept = new FileInfo(download.PartialPath);
            if (!kept.Exists || kept.Length != 1000)
                throw new Exception("the partial was not kept for the next attempt");
            if (File.Exists(c.Destination)) throw new Exception("destination exists");
        }
    }

    private static void NoDigestAfter416()
    {
        using (var c = new Case("no-digest", x => x.FromRange()))
        {
            c.WritePartial(Body);
            c.Download(null, 0).Run();
            c.AssertFinal();
            c.AssertRanges("300000,-1");
        }
    }

    private static void ExpectFailure<T>(ResumableDownload download) where T : Exception
    {
        try { download.Run(); }
        catch (T) { return; }
        catch (Exception exception)
        {
            throw new Exception("expected " + typeof(T).Name + ", got " +
                exception.GetType().Name + ": " + exception.Message);
        }
        throw new Exception("expected " + typeof(T).Name + ", but the download succeeded");
    }

    private static void Run(string name, Action test)
    {
        try
        {
            test();
            Console.WriteLine("ok   " + name);
        }
        catch (Exception exception)
        {
            failures++;
            Console.WriteLine("FAIL " + name + ": " + exception.Message);
        }
    }

    private static byte[] CreateBody(int length, int seed)
    {
        var bytes = new byte[length];
        new Random(seed).NextBytes(bytes);
        return bytes;
    }

    private static byte[] Slice(byte[] source, int offset, int count)
    {
        var result = new byte[count];
        Buffer.BlockCopy(source, offset, result, 0, count);
        return result;
    }

    private static byte[] Corrupt(byte[] source)
    {
        var result = (byte[])source.Clone();
        result[result.Length / 2] ^= 0xff;
        return result;
    }

    private static string Sha(byte[] bytes)
    {
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    private sealed class Case : IDisposable
    {
        public readonly Server Server;
        public readonly string Destination;
        private readonly List<string> events = new List<string>();

        public Case(string name, Action<Exchange> handler)
        {
            Destination = Path.Combine(root, name + ".bin");
            Server = new Server(handler);
        }

        public ResumableDownload Download(string sha256, long size)
        {
            return new ResumableDownload
            {
                Url = Server.Url,
                Destination = Destination,
                Sha256 = sha256,
                ExpectedSize = size,
                UserAgent = "VoxType-Download-Tests",
                StallTimeoutMilliseconds = 1000,
                RetryDelayMilliseconds = 10,
                MaximumAttemptsWithoutProgress = 3,
                Progress = delegate(DownloadPhase phase, long received, long total)
                {
                    lock (events) events.Add(phase + ":" + received + "/" + total);
                }
            };
        }

        public void WritePartial(byte[] bytes) { File.WriteAllBytes(Destination + ".partial", bytes); }

        public void AssertFinal()
        {
            if (File.Exists(Destination + ".partial")) throw new Exception("a .partial file remains");
            if (!File.Exists(Destination)) throw new Exception("the destination is missing");
            if (Sha(File.ReadAllBytes(Destination)) != BodySha)
                throw new Exception("the destination does not match the served file");
        }

        public void AssertNoFiles()
        {
            if (File.Exists(Destination)) throw new Exception("the destination exists");
            if (File.Exists(Destination + ".partial")) throw new Exception("a .partial file remains");
        }

        public void AssertRanges(string expected)
        {
            var actual = Server.Ranges;
            if (actual != expected)
                throw new Exception("requested ranges <" + actual + ">, expected <" + expected + ">");
        }

        public void AssertEvent(string expected)
        {
            lock (events)
            {
                if (!events.Contains(expected))
                    throw new Exception("no progress event " + expected + " in " +
                        String.Join(" ", events.ToArray()));
            }
        }

        public void Dispose() { Server.Dispose(); }
    }

    private sealed class Exchange
    {
        public int Index;
        public long RangeStart;
        public NetworkStream Stream;

        public void Head(string status, long length, string extraHeaders)
        {
            var text = "HTTP/1.1 " + status + "\r\nContent-Type: application/octet-stream\r\n" +
                "Content-Length: " + length + "\r\n" + (extraHeaders ?? "") +
                "Connection: close\r\n\r\n";
            var bytes = Encoding.ASCII.GetBytes(text);
            Stream.Write(bytes, 0, bytes.Length);
            Stream.Flush();
        }

        public void Data(long offset, long count)
        {
            Stream.Write(Body, (int)offset, (int)count);
            Stream.Flush();
        }

        public void Full()
        {
            Head("200 OK", Body.Length, null);
            Data(0, Body.Length);
        }

        public void PartialFrom(long start)
        {
            Head("206 Partial Content", Body.Length - start, ContentRange(start));
            Data(start, Body.Length - start);
        }

        public void FromRange()
        {
            if (RangeStart < 0) Full();
            else if (RangeStart >= Body.Length) Head("416 Range Not Satisfiable", 0, null);
            else PartialFrom(RangeStart);
        }

        // Announces the rest of the file, sends `count` bytes of it, then goes silent.
        public void Stall(long count, int milliseconds)
        {
            var start = RangeStart < 0 ? 0 : RangeStart;
            if (RangeStart < 0) Head("200 OK", Body.Length, null);
            else Head("206 Partial Content", Body.Length - start, ContentRange(start));
            if (count > 0) Data(start, count);
            Thread.Sleep(milliseconds);
        }

        // Announces the rest of the file but closes the connection after `count` bytes.
        public void Truncate(long count)
        {
            var start = RangeStart < 0 ? 0 : RangeStart;
            if (RangeStart < 0) Head("200 OK", Body.Length, null);
            else Head("206 Partial Content", Body.Length - start, ContentRange(start));
            Data(start, count);
        }

        private static string ContentRange(long start)
        {
            return "Content-Range: bytes " + start + "-" + (Body.Length - 1) + "/" + Body.Length +
                "\r\n";
        }
    }

    private sealed class Server : IDisposable
    {
        private readonly TcpListener listener;
        private readonly Action<Exchange> handler;
        private readonly List<long> ranges = new List<long>();
        public readonly string Url;

        public Server(Action<Exchange> handler)
        {
            this.handler = handler;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/model.bin";
            var thread = new Thread(Accept);
            thread.IsBackground = true;
            thread.Start();
        }

        public string Ranges
        {
            get
            {
                lock (ranges)
                {
                    var parts = new List<string>();
                    foreach (var range in ranges) parts.Add(range.ToString());
                    return String.Join(",", parts.ToArray());
                }
            }
        }

        private void Accept()
        {
            while (true)
            {
                TcpClient client;
                try { client = listener.AcceptTcpClient(); }
                catch { return; }
                var worker = new Thread(delegate() { Serve(client); });
                worker.IsBackground = true;
                worker.Start();
            }
        }

        private void Serve(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    var range = ReadRange(stream);
                    int index;
                    lock (ranges)
                    {
                        index = ranges.Count;
                        ranges.Add(range);
                    }
                    handler(new Exchange { Index = index, RangeStart = range, Stream = stream });
                }
                catch (IOException) { }
                catch (SocketException) { }
                catch (ObjectDisposedException) { }
            }
        }

        // Reads the request head and returns the start of "Range: bytes=<start>-", or -1.
        private static long ReadRange(NetworkStream stream)
        {
            var head = new StringBuilder();
            while (!head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            {
                var value = stream.ReadByte();
                if (value < 0) throw new IOException("request ended early");
                head.Append((char)value);
            }
            foreach (var line in head.ToString().Split(new[] { "\r\n" }, StringSplitOptions.None))
            {
                if (!line.StartsWith("Range:", StringComparison.OrdinalIgnoreCase)) continue;
                var spec = line.Substring(6).Trim();
                if (!spec.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) continue;
                var dash = spec.IndexOf('-');
                return Int64.Parse(spec.Substring(6, dash - 6));
            }
            return -1;
        }

        public void Dispose() { listener.Stop(); }
    }
}
