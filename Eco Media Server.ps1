#requires -Version 5.1
<#
  Eco Media Server 1.2 - single-file WPF/DLNA server
  Run: powershell.exe -ExecutionPolicy Bypass -File .\EcoMediaServer.ps1
  Windows PowerShell 5.1 (STA) recommended.
#>

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'))
    exit
}

# Runs as the current user so Explorer drag-and-drop remains available.
# Network access is handled by a user-mode TCP listener; no URLACL or UAC elevation is needed.

# Load WPF and hide the console used to launch the desktop application.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleWindow {
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  public static void Hide() { var h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
}
"@
[ConsoleWindow]::Hide()

# Embedded C# engine: HTTP handling, media catalog, UPnP actions, and SSDP discovery.
$engine = @'
using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Security;
using System.Runtime.InteropServices;


// Parsed HTTP request data and response writer.
public sealed class SimpleHttpRequest {
    public string HttpMethod, AbsolutePath, Body;
    public readonly Dictionary<string,string> Headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    public IPEndPoint RemoteEndPoint;
}
public sealed class SimpleHttpResponse {
    readonly Stream stream;
    readonly Dictionary<string,string> headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    bool started;
    public int StatusCode = 200;
    public string ContentType { set { headers["Content-Type"] = value; } }
    public long ContentLength64 { set { headers["Content-Length"] = value.ToString(); } }
    public IDictionary<string,string> Headers { get { return headers; } }
    public Stream OutputStream { get { Start(); return stream; } }
    public SimpleHttpResponse(Stream s) { stream=s; }
    void Start() {
        if(started) return; started=true;
        string reason=StatusCode==200?"OK":StatusCode==206?"Partial Content":StatusCode==400?"Bad Request":StatusCode==404?"Not Found":StatusCode==412?"Precondition Failed":StatusCode==416?"Range Not Satisfiable":StatusCode==500?"Internal Server Error":"OK";
        var sb=new StringBuilder("HTTP/1.1 "+StatusCode+" "+reason+"\r\n");
        foreach(var h in headers) sb.Append(h.Key).Append(": ").Append(h.Value).Append("\r\n");
        sb.Append("Connection: close\r\n\r\n");
        byte[] head=Encoding.ASCII.GetBytes(sb.ToString()); stream.Write(head,0,head.Length);
    }
    public void Close() { Start(); stream.Flush(); }
}

// Reads one HTTP request and creates its response context.
public sealed class SimpleHttpContext {
    public SimpleHttpRequest Request;
    public SimpleHttpResponse Response;
    public static SimpleHttpContext Read(Stream stream, IPEndPoint remote) {
        var bytes=new List<byte>(); int state=0;
        while(bytes.Count<65536) { int b=stream.ReadByte(); if(b<0)return null; bytes.Add((byte)b); state=(state==0&&b==13)?1:(state==1&&b==10)?2:(state==2&&b==13)?3:(state==3&&b==10)?4:0; if(state==4)break; }
        if(state!=4)return null;
        string raw=Encoding.ASCII.GetString(bytes.ToArray()); string[] lines=raw.Split(new[]{"\r\n"},StringSplitOptions.None);
        if(lines.Length==0)return null; string[] first=lines[0].Split(' '); if(first.Length<2)return null;
        var req=new SimpleHttpRequest{HttpMethod=first[0],AbsolutePath=new Uri("http://localhost"+first[1]).AbsolutePath,RemoteEndPoint=remote};
        for(int i=1;i<lines.Length;i++){int k=lines[i].IndexOf(':');if(k>0)req.Headers[lines[i].Substring(0,k).Trim()]=lines[i].Substring(k+1).Trim();}
        int len=0; string hv; if(req.Headers.TryGetValue("Content-Length",out hv)) Int32.TryParse(hv,out len); req.Body="";
        if(len>0 && len<=1048576){byte[] body=new byte[len];int o=0;while(o<len){int n=stream.Read(body,o,len-o);if(n<=0)break;o+=n;}req.Body=Encoding.UTF8.GetString(body,0,o);}
        return new SimpleHttpContext{Request=req,Response=new SimpleHttpResponse(stream)};
    }
}

// Metadata for one file shared by the server.
public sealed class EmsItem {
    public string Id, Path, Title, Mime;
    public long Length;
}

// Owns the media catalog, network listeners, and their worker threads.
public sealed class EcoDlnaServerScan : IDisposable {
    const string Version = "1.2";
    [DllImport("iphlpapi.dll", ExactSpelling=true)]
    static extern int GetBestInterface(uint destinationAddress, out uint interfaceIndex);

    readonly object sync = new object();
    readonly List<EmsItem> items = new List<EmsItem>();
    readonly ConcurrentQueue<string> logs = new ConcurrentQueue<string>();
    TcpListener http;
    UdpClient ssdp;
    string host;
    int port;
    readonly string uuid = StableUuid();
    static string StableUuid() { using(var m=System.Security.Cryptography.MD5.Create()){return "uuid:"+new Guid(m.ComputeHash(Encoding.UTF8.GetBytes("EcoMediaServer|"+Environment.MachineName))).ToString();} }
    public bool Running { get; private set; }
    public string Address { get { return host + ":" + port; } }
    public int ItemCount { get { lock(sync) return items.Count; } }
    public long TotalBytes { get { lock(sync) return items.Sum(x => x.Length); } }

    public void Add(string path) {
        if (!File.Exists(path)) return;
        lock(sync) {
            if (items.Any(x => String.Equals(x.Path, path, StringComparison.OrdinalIgnoreCase))) return;
            var f = new FileInfo(path);
            items.Add(new EmsItem { Id=Guid.NewGuid().ToString("N"), Path=f.FullName, Title=System.IO.Path.GetFileNameWithoutExtension(f.Name), Mime=Mime(f.Extension), Length=f.Length });
        }
        Log("MEDIA ADDED  " + System.IO.Path.GetFileName(path));
    }
    public void Remove(string id) { lock(sync) items.RemoveAll(x => x.Id == id); }
    public EmsItem[] Snapshot() { lock(sync) return items.ToArray(); }
    public string[] DrainLogs() { var a=new List<string>(); string s; while(logs.TryDequeue(out s)) a.Add(s); return a.ToArray(); }
    void Log(string s) { logs.Enqueue(DateTime.Now.ToString("HH:mm:ss") + "  " + s); }

    public void Start(int requestedPort) {
        if (Running) return;
        host = FindIPv4(); port = requestedPort;
        http = new TcpListener(IPAddress.Parse(host), port);
        http.Start();
        Running=true;
        var httpThread=new Thread(HttpLoop){IsBackground=true}; httpThread.Start();
        try {
            ssdp = new UdpClient(); ssdp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            ssdp.Client.Bind(new IPEndPoint(IPAddress.Any,1900));
            ssdp.JoinMulticastGroup(IPAddress.Parse("239.255.255.250"), IPAddress.Parse(host));
            var ssdpThread=new Thread(SsdpLoop){IsBackground=true}; ssdpThread.Start();
            var notifyThread=new Thread(NotifyLoop){IsBackground=true}; notifyThread.Start();
        } catch(Exception ex) { Log("SSDP WARNING  " + ex.Message); }
        Log("SERVER ONLINE  " + Address);
    }

    string FindIPv4() {
        var candidates = new List<Tuple<int,IPAddress,bool,string>>();
        foreach(NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces()) {
            if(nic.OperationalStatus!=OperationalStatus.Up ||
                nic.NetworkInterfaceType==NetworkInterfaceType.Loopback ||
                nic.NetworkInterfaceType==NetworkInterfaceType.Tunnel) continue;
            var properties=nic.GetIPProperties();
            var ipv4=properties.GetIPv4Properties();
            if(ipv4==null) continue;
            bool hasGateway=properties.GatewayAddresses.Any(g =>
                g.Address.AddressFamily==AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
            foreach(var unicast in properties.UnicastAddresses) {
                IPAddress address=unicast.Address;
                if(address.AddressFamily==AddressFamily.InterNetwork && IsPrivateIPv4(address))
                    candidates.Add(Tuple.Create(ipv4.Index,address,hasGateway,nic.Name));
            }
        }

        if(candidates.Count==0)
            throw new InvalidOperationException("No active private IPv4 network interface was found.");

        byte[] group=IPAddress.Parse("239.255.255.250").GetAddressBytes();
        uint bestIndex;
        bool hasGatewayCandidate=candidates.Any(c=>c.Item3);
        if(GetBestInterface(BitConverter.ToUInt32(group,0),out bestIndex)==0) {
            var routed=candidates.FirstOrDefault(c=>c.Item1==(int)bestIndex && (c.Item3 || !hasGatewayCandidate));
            if(routed!=null) return routed.Item2.ToString();
        }

        var gatewayCandidates=candidates.Where(c=>c.Item3).ToArray();
        if(gatewayCandidates.Select(c=>c.Item1).Distinct().Count()==1)
            return gatewayCandidates[0].Item2.ToString();
        if(candidates.Select(c=>c.Item1).Distinct().Count()==1)
            return candidates[0].Item2.ToString();

        string found=String.Join("; ",candidates.Select(c=>c.Item4+" ("+c.Item2+")").Distinct());
        throw new InvalidOperationException("Could not select one LAN interface for SSDP. Available interfaces: "+found);
    }

    static bool IsPrivateIPv4(IPAddress address) {
        byte[] b=address.GetAddressBytes();
        return b[0]==10 || (b[0]==172 && b[1]>=16 && b[1]<=31) || (b[0]==192 && b[1]==168);
    }

    void HttpLoop() {
        while(Running) try { var client=http.AcceptTcpClient(); ThreadPool.QueueUserWorkItem(_=>HandleClient(client)); }
        catch { if(Running) Thread.Sleep(50); }
    }
    void HandleClient(TcpClient client) {
        using(client) try {
            client.NoDelay = true;
            var stream = client.GetStream();
            var c = SimpleHttpContext.Read(stream, client.Client.RemoteEndPoint as IPEndPoint);
            if(c == null) return;
            Handle(c);
        } catch(Exception ex) { if(Running) Log("HTTP ERROR  "+ex.Message); }
    }
    // Routes HTTP requests to device, SOAP, event, or media handlers.
    void Handle(SimpleHttpContext c) {
        try {
            string p=c.Request.AbsolutePath, method=c.Request.HttpMethod.ToUpperInvariant();
            if((p=="/" || p=="/device.xml") && (method=="GET" || method=="HEAD")) Xml(c,DeviceXml());
            else if(p=="/content/scpd.xml" && (method=="GET" || method=="HEAD")) Xml(c,ContentScpd());
            else if(p=="/connection/scpd.xml" && (method=="GET" || method=="HEAD")) Xml(c,ConnectionScpd());
            else if(p=="/content/control" && method=="POST") ContentControl(c);
            else if(p=="/connection/control" && method=="POST") ConnectionControl(c);
            else if((p=="/content/event" || p=="/connection/event") && (method=="SUBSCRIBE" || method=="UNSUBSCRIBE")) Event(c);
            else if(p.StartsWith("/media/") && (method=="GET" || method=="HEAD")) Media(c,p.Substring(7));
            else { c.Response.StatusCode=404;c.Response.ContentLength64=0;c.Response.Close(); }
        } catch(Exception ex) { try { SoapFault(c,501,"Action Failed"); } catch{} Log("HTTP ERROR  "+ex.Message); }
    }
    string Action(SimpleHttpContext c) { string a; if(!c.Request.Headers.TryGetValue("SOAPACTION",out a))return "";a=a.Trim().Trim('"');int k=a.LastIndexOf('#');return k>=0?a.Substring(k+1):a; }
    void Empty(SimpleHttpContext c) { c.Response.ContentLength64=0;c.Response.Close(); }
    void Event(SimpleHttpContext c) {
        if(c.Request.HttpMethod.Equals("UNSUBSCRIBE",StringComparison.OrdinalIgnoreCase)){Empty(c);return;}
        string sid;if(!c.Request.Headers.TryGetValue("SID",out sid))sid="uuid:"+Guid.NewGuid().ToString();
        c.Response.Headers["SID"]=sid;c.Response.Headers["TIMEOUT"]="Second-1800";Empty(c);
    }
    void Soap(SimpleHttpContext c,string service,string action,string inner) { string body="<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:"+action+"Response xmlns:u=\"urn:schemas-upnp-org:service:"+service+":1\">"+inner+"</u:"+action+"Response></s:Body></s:Envelope>";Xml(c,body); }
    void SoapFault(SimpleHttpContext c,int code,string description) { c.Response.StatusCode=500;string body="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>"+code+"</errorCode><errorDescription>"+description+"</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>";Xml(c,body); }
    void Xml(SimpleHttpContext c,string text) {
        byte[] b=Encoding.UTF8.GetBytes(text); c.Response.ContentType="text/xml; charset=utf-8"; c.Response.ContentLength64=b.Length;
        if(c.Request.HttpMethod!="HEAD") c.Response.OutputStream.Write(b,0,b.Length); c.Response.Close();
    }
    // UPnP device and service descriptions.
    string DeviceXml() { return "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\" xmlns:dlna=\"urn:schemas-dlna-org:device-1-0\" xmlns:sec=\"http://www.sec.co.kr/dlna\"><specVersion><major>1</major><minor>0</minor></specVersion><URLBase>http://"+Address+"/</URLBase><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>Eco Media Server</friendlyName><manufacturer>eco-by-different</manufacturer><modelName>Eco Media Server</modelName><modelNumber>"+Version+"</modelNumber><serialNumber>2026</serialNumber><dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC><sec:ProductCap>smi,DCM10,getMediaInfo.sec,getCaptionInfo.sec</sec:ProductCap><sec:X_ProductCap>smi,DCM10,getMediaInfo.sec,getCaptionInfo.sec</sec:X_ProductCap><UDN>"+uuid+"</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId><controlURL>/content/control</controlURL><eventSubURL>/content/event</eventSubURL><SCPDURL>/content/scpd.xml</SCPDURL></service><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><controlURL>/connection/control</controlURL><eventSubURL>/connection/event</eventSubURL><SCPDURL>/connection/scpd.xml</SCPDURL></service></serviceList></device></root>"; }
    string ContentScpd() { return "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList><action><name>Browse</name><argumentList><argument><name>ObjectID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument><argument><name>BrowseFlag</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_BrowseFlag</relatedStateVariable></argument><argument><name>Filter</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Filter</relatedStateVariable></argument><argument><name>StartingIndex</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Index</relatedStateVariable></argument><argument><name>RequestedCount</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>SortCriteria</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SortCriteria</relatedStateVariable></argument><argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument><argument><name>NumberReturned</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>TotalMatches</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Count</relatedStateVariable></argument><argument><name>UpdateID</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument></argumentList></action><action><name>GetSearchCapabilities</name><argumentList><argument><name>SearchCaps</name><direction>out</direction><relatedStateVariable>SearchCapabilities</relatedStateVariable></argument></argumentList></action><action><name>GetSortCapabilities</name><argumentList><argument><name>SortCaps</name><direction>out</direction><relatedStateVariable>SortCapabilities</relatedStateVariable></argument></argumentList></action><action><name>GetSystemUpdateID</name><argumentList><argument><name>Id</name><direction>out</direction><relatedStateVariable>SystemUpdateID</relatedStateVariable></argument></argumentList></action></actionList><serviceStateTable><stateVariable sendEvents=\"yes\"><name>SystemUpdateID</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>SearchCapabilities</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>SortCapabilities</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_BrowseFlag</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_Filter</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_Index</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_Count</name><dataType>ui4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_SortCriteria</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable></serviceStateTable></scpd>"; }
    string ConnectionScpd() { return "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList><action><name>GetProtocolInfo</name><argumentList><argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument><argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument></argumentList></action><action><name>GetCurrentConnectionIDs</name><argumentList><argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument></argumentList></action><action><name>GetCurrentConnectionInfo</name><argumentList><argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument><argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument><argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument><argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument><argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument><argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument><argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument></argumentList></action></actionList><serviceStateTable><stateVariable sendEvents=\"yes\"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"yes\"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"yes\"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable><stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable></serviceStateTable></scpd>"; }
    string SoapValue(string body,string name) { if(String.IsNullOrEmpty(body))return "";string a="<"+name+">",z="</"+name+">";int i=body.IndexOf(a,StringComparison.OrdinalIgnoreCase);if(i<0)return "";i+=a.Length;int j=body.IndexOf(z,i,StringComparison.OrdinalIgnoreCase);return j<0?"":body.Substring(i,j-i); }
    string DlnaClass(string mime) { if(mime.StartsWith("audio/"))return "object.item.audioItem.musicTrack";if(mime.StartsWith("image/"))return "object.item.imageItem.photo";return "object.item.videoItem"; }
    static bool IsOp11Format(string mime) { return mime=="video/mp4"||mime=="video/x-matroska"||mime=="video/x-msvideo"||mime=="video/quicktime"; }

    // SOAP actions for ContentDirectory and ConnectionManager.
    void ContentControl(SimpleHttpContext c) {
        string a=Action(c);
        if(a=="Browse") Browse(c);
        else if(a=="GetSearchCapabilities") Soap(c,"ContentDirectory","GetSearchCapabilities","<SearchCaps></SearchCaps>");
        else if(a=="GetSortCapabilities") Soap(c,"ContentDirectory","GetSortCapabilities","<SortCaps>dc:title</SortCaps>");
        else if(a=="GetSystemUpdateID") Soap(c,"ContentDirectory","GetSystemUpdateID","<Id>1</Id>");
        else SoapFault(c,401,"Invalid Action");
    }
    void ConnectionControl(SimpleHttpContext c) {
        string a=Action(c);
        if(a=="GetProtocolInfo") ProtocolInfo(c);
        else if(a=="GetCurrentConnectionIDs") Soap(c,"ConnectionManager","GetCurrentConnectionIDs","<ConnectionIDs></ConnectionIDs>");
        else if(a=="GetCurrentConnectionInfo") Soap(c,"ConnectionManager","GetCurrentConnectionInfo","<RcsID>-1</RcsID><AVTransportID>-1</AVTransportID><ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>Unknown</Status>");
        else SoapFault(c,401,"Invalid Action");
    }
    // Catalog browsing, advertised protocols, and byte-range media delivery.
    void Browse(SimpleHttpContext c) {
        bool metadata=SoapValue(c.Request.Body,"BrowseFlag").Equals("BrowseMetadata",StringComparison.OrdinalIgnoreCase);int first=0,count=0;Int32.TryParse(SoapValue(c.Request.Body,"StartingIndex"),out first);Int32.TryParse(SoapValue(c.Request.Body,"RequestedCount"),out count);
        EmsItem[] all=Snapshot();IEnumerable<EmsItem> q=all.Skip(first);if(count>0)q=q.Take(count);EmsItem[] selected=q.ToArray();var sb=new StringBuilder();
        if(metadata)sb.Append("<container id=\"0\" parentID=\"-1\" restricted=\"1\" searchable=\"0\" childCount=\"").Append(all.Length).Append("\"><dc:title>Eco Media Server</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>");
        else foreach(EmsItem x in selected){string t=SecurityElement.Escape(x.Title),u="http://"+Address+"/media/"+x.Id,op=IsOp11Format(x.Mime)?"11":"01";sb.Append("<item id=\"").Append(x.Id).Append("\" parentID=\"0\" restricted=\"1\"><dc:title>").Append(t).Append("</dc:title><upnp:class>").Append(DlnaClass(x.Mime)).Append("</upnp:class><res protocolInfo=\"http-get:*:").Append(x.Mime).Append(":DLNA.ORG_OP=").Append(op).Append(";DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\" size=\"").Append(x.Length).Append("\">").Append(u).Append("</res></item>");}
        int returned=metadata?1:selected.Length,total=metadata?1:all.Length;string didl="<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:sec=\"http://www.sec.co.kr/\">"+sb+"</DIDL-Lite>";
        string body="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>"+SecurityElement.Escape(didl)+"</Result><NumberReturned>"+returned+"</NumberReturned><TotalMatches>"+total+"</TotalMatches><UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>";Xml(c,body);Log("CATALOG "+(metadata?"METADATA":"CHILDREN")+" ITEMS="+returned);
    }
    void ProtocolInfo(SimpleHttpContext c) {
        string source=String.Join(",",new[]{"video/mp4","video/x-matroska","video/x-msvideo","video/mpeg","video/quicktime","audio/mpeg","audio/flac","audio/wav","image/jpeg","image/png"}.Select(x=>"http-get:*:"+x+":DLNA.ORG_OP="+(IsOp11Format(x)?"11":"01")+";DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"));
        Soap(c,"ConnectionManager","GetProtocolInfo","<Source>"+SecurityElement.Escape(source)+"</Source><Sink></Sink>");
    }
    void Media(SimpleHttpContext c,string id) {
        EmsItem x; lock(sync) x=items.FirstOrDefault(z=>z.Id==id); if(x==null || !File.Exists(x.Path)){c.Response.StatusCode=404;c.Response.ContentLength64=0;c.Response.Close();return;}
        long start=0,end=x.Length-1; string r=(c.Request.Headers.ContainsKey("Range") ? c.Request.Headers["Range"] : null);
        if(!String.IsNullOrEmpty(r) && r.StartsWith("bytes=",StringComparison.OrdinalIgnoreCase)) {
            var q=r.Substring(6).Split('-'); long parsed=0;
            bool valid=q.Length==2 && q[0].Length>0 && long.TryParse(q[0],out parsed) && parsed>=0 && parsed<x.Length;
            if(valid){start=parsed;if(q[1].Length>0){valid=long.TryParse(q[1],out parsed) && parsed>=start;if(valid)end=Math.Min(parsed,x.Length-1);}}
            if(!valid){c.Response.StatusCode=416;c.Response.Headers["Content-Range"]="bytes */"+x.Length;c.Response.ContentLength64=0;c.Response.Close();return;}
            c.Response.StatusCode=206;c.Response.Headers["Content-Range"]="bytes "+start+"-"+end+"/"+x.Length;
        }
        c.Response.ContentType=x.Mime;c.Response.Headers["Accept-Ranges"]="bytes";
        if(IsOp11Format(x.Mime)){
            c.Response.Headers["transferMode.dlna.org"]="Streaming";
            c.Response.Headers["contentFeatures.dlna.org"]="DLNA.ORG_OP=11;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000";
        }
        c.Response.ContentLength64=end-start+1;
        if(c.Request.HttpMethod!="HEAD") using(var f=new FileStream(x.Path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)){ f.Position=start; byte[] b=new byte[1024*256]; long left=end-start+1; while(left>0){int n=f.Read(b,0,(int)Math.Min(b.Length,left));if(n<=0)break;c.Response.OutputStream.Write(b,0,n);left-=n;}}
        c.Response.Close(); Log("STREAM  "+x.Title+"  -> "+c.Request.RemoteEndPoint.Address);
    }
    // SSDP discovery responses and periodic alive/byebye announcements.
    string[] SsdpTypes() { return new[]{
        "upnp:rootdevice",
        uuid,
        "urn:schemas-upnp-org:device:MediaServer:1",
        "urn:schemas-upnp-org:service:ContentDirectory:1",
        "urn:schemas-upnp-org:service:ConnectionManager:1"
    }; }
    string Header(string text,string name) {
        foreach(var line in text.Split(new[]{"\r\n"},StringSplitOptions.RemoveEmptyEntries)) {
            int k=line.IndexOf(':'); if(k>0 && line.Substring(0,k).Trim().Equals(name,StringComparison.OrdinalIgnoreCase)) return line.Substring(k+1).Trim();
        }
        return "";
    }
    string Usn(string type) { return type==uuid ? uuid : uuid+"::"+type; }
    void SsdpLoop() {
        var ep=new IPEndPoint(IPAddress.Any,0);
        while(Running) try {
            var b=ssdp.Receive(ref ep); string text=Encoding.ASCII.GetString(b);
            if(text.IndexOf("M-SEARCH",StringComparison.OrdinalIgnoreCase)<0) continue;
            string man=Header(text,"MAN"), st=Header(text,"ST");
            if(man.IndexOf("ssdp:discover",StringComparison.OrdinalIgnoreCase)<0) continue;
            Log("SSDP SEARCH  "+ep.Address+"  ST="+st);
            if(st.Equals("ssdp:all",StringComparison.OrdinalIgnoreCase)) foreach(var t in SsdpTypes()) Reply(ep,t);
            else foreach(var t in SsdpTypes()) if(st.Equals(t,StringComparison.OrdinalIgnoreCase)) Reply(ep,t);
        } catch(Exception ex) { if(Running){Log("SSDP ERROR  "+ex.Message);Thread.Sleep(100);} }
    }
    void Reply(IPEndPoint ep,string st) {
        string m="HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: "+DateTime.UtcNow.ToString("R")+"\r\nEXT:\r\nLOCATION: http://"+Address+"/device.xml\r\nSERVER: Windows/10.0 UPnP/1.0 DLNADOC/1.50 EcoMediaServer/"+Version+"\r\nST: "+st+"\r\nUSN: "+Usn(st)+"\r\nBOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1\r\n\r\n";
        byte[] b=Encoding.ASCII.GetBytes(m); ssdp.Send(b,b.Length,ep); Log("SSDP REPLY  "+ep.Address+"  "+st);
    }
    void NotifyLoop() {
        int cycle=0; while(Running){ try { foreach(var t in SsdpTypes()) NotifyOne("ssdp:alive",t); }catch(Exception ex){Log("NOTIFY ERROR  "+ex.Message);} int seconds=cycle<2?2:60;cycle++;for(int i=0;i<seconds && Running;i++)Thread.Sleep(1000); }
    }
    void Notify(string nts) { foreach(var t in SsdpTypes()) NotifyOne(nts,t); }
    void NotifyOne(string nts,string nt) {
        string m="NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://"+Address+"/device.xml\r\nNT: "+nt+"\r\nNTS: "+nts+"\r\nSERVER: Windows/10.0 UPnP/1.0 DLNADOC/1.50 EcoMediaServer/"+Version+"\r\nUSN: "+Usn(nt)+"\r\nBOOTID.UPNP.ORG: 1\r\nCONFIGID.UPNP.ORG: 1\r\n\r\n";
        byte[] b=Encoding.ASCII.GetBytes(m);
        using(var u=new UdpClient(new IPEndPoint(IPAddress.Parse(host),0))) { u.MulticastLoopback=false; u.Send(b,b.Length,new IPEndPoint(IPAddress.Parse("239.255.255.250"),1900)); }
    }
    // File extension to HTTP media type mapping.
    static string Mime(string e) { switch(e.ToLowerInvariant()){case ".mp4":case ".m4v":return "video/mp4";case ".mov":return "video/quicktime";case ".mkv":return "video/x-matroska";case ".avi":return "video/x-msvideo";case ".mpg":case ".mpeg":case ".ts":case ".m2ts":return "video/mpeg";case ".mp3":return "audio/mpeg";case ".flac":return "audio/flac";case ".wav":return "audio/wav";case ".jpg":case ".jpeg":return "image/jpeg";case ".png":return "image/png";default:return "application/octet-stream";} }
    public void Dispose(){ Running=false; try{Notify("ssdp:byebye");}catch{} try{http.Stop();}catch{} try{ssdp.Close();}catch{} Log("SERVER STOPPED"); }
}
'@
# Compile the embedded server engine before loading the WPF window.
try { Add-Type -TypeDefinition $engine -Language CSharp -ErrorAction Stop } catch { [System.Windows.MessageBox]::Show("The server engine could not be compiled.`n`n$($_.Exception.Message)","Eco Media Server"); return }

# WPF window layout and visual styling.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Eco Media Server" Width="1180" Height="760" MinWidth="900" MinHeight="620" WindowStartupLocation="CenterScreen"
 WindowStyle="None" ResizeMode="CanResizeWithGrip" Background="#071011" AllowDrop="True" FontFamily="Segoe UI">
 <Window.Resources>
  <SolidColorBrush x:Key="Accent" Color="#62F3C3"/><SolidColorBrush x:Key="Muted" Color="#789291"/><SolidColorBrush x:Key="Line" Color="#254547"/>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#D9E8E6"/><Setter Property="Background" Value="#101C1E"/><Setter Property="BorderBrush" Value="#426263"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="18,9"/><Setter Property="FontFamily" Value="Cascadia Mono"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="1"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#17453F"/><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#62F3C3"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#62F3C3"/><Setter Property="Foreground" Value="#071011"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#62F3C3"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#D9E8E6"/></Style>
 </Window.Resources>
 <Border BorderBrush="#265A58" BorderThickness="1" CornerRadius="8" Background="#071011">
 <Grid>
  <Grid.RowDefinitions><RowDefinition Height="76"/><RowDefinition Height="*"/><RowDefinition Height="104"/><RowDefinition Height="36"/></Grid.RowDefinitions>
  <!-- watermark -->
  <Grid Grid.RowSpan="4" IsHitTestVisible="False" Opacity="0.085" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-150,-170" Width="700" Height="700">
   <Ellipse Stroke="#43DDAE" StrokeThickness="3" Margin="30"/><Ellipse Stroke="#43DDAE" StrokeThickness="1" StrokeDashArray="4,9" Margin="72"/>
   <StackPanel VerticalAlignment="Center"><TextBlock Text="ECO" FontFamily="Cascadia Mono" FontSize="150" FontWeight="Bold" Foreground="#43DDAE" HorizontalAlignment="Center"/><TextBlock Text="MEDIA SERVER" FontFamily="Cascadia Mono" FontSize="30" Foreground="#43DDAE" HorizontalAlignment="Center"/></StackPanel>
  </Grid>
  <!-- title -->
  <Grid x:Name="TitleBar" Grid.Row="0" Background="#0A1516"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
   <StackPanel Orientation="Horizontal" Margin="24,12"><TextBlock Text="▷" FontSize="44" Foreground="{StaticResource Accent}" Margin="0,-6,18,0"/><StackPanel><TextBlock Text="ECO MEDIA SERVER" FontFamily="Cascadia Mono" FontSize="25" FontWeight="Bold" Foreground="{StaticResource Accent}"/><TextBlock Text="LOCAL MEDIA TRANSMISSION SYSTEM" FontFamily="Cascadia Mono" FontSize="11" Foreground="{StaticResource Muted}"/></StackPanel></StackPanel>
   <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="MinButton" Content="—" Width="52" BorderThickness="0" Background="Transparent"/><Button x:Name="CloseButton" Content="×" FontSize="22" Width="52" BorderThickness="0" Background="Transparent"/></StackPanel>
  </Grid>
  <!-- content -->
  <Grid Grid.Row="1" Margin="20,18,20,14"><Grid.RowDefinitions><RowDefinition Height="190"/><RowDefinition Height="12"/><RowDefinition Height="*"/></Grid.RowDefinitions>
   <Border x:Name="DropZone" BorderBrush="{StaticResource Accent}" BorderThickness="1" CornerRadius="6" Background="#97101D1F"><StackPanel VerticalAlignment="Center"><TextBlock Text="⇩" FontSize="46" HorizontalAlignment="Center" Foreground="{StaticResource Accent}"/><TextBlock Text="DROP MEDIA HERE" FontFamily="Cascadia Mono" FontSize="26" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{StaticResource Accent}"/><TextBlock Text="Files or folders" HorizontalAlignment="Center" Foreground="#A2BBB8" Margin="0,4,0,15"/><Button x:Name="BrowseButton" Content="SELECT FILES" HorizontalAlignment="Center" Width="240"/></StackPanel></Border>
   <Border Grid.Row="2" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Background="#B0071112"><Grid><Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid Grid.Row="0"><TextBlock x:Name="ItemsHeader" Text="SHARED ITEMS ( 0 )" Margin="14,13" FontFamily="Cascadia Mono" Foreground="{StaticResource Accent}"/><TextBlock x:Name="SizeHeader" Text="TOTAL SIZE: 0 B" HorizontalAlignment="Right" Margin="0,13,16,0" FontFamily="Cascadia Mono" Foreground="#91A7A5"/></Grid><DataGrid x:Name="MediaList" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserResizeRows="False" IsReadOnly="True" SelectionMode="Extended" SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#183638" RowHeight="27" ColumnHeaderHeight="30" RowBackground="#70071112" AlternatingRowBackground="#70101C1E" Background="Transparent" BorderThickness="0" Foreground="#DDE9E7" FontFamily="Cascadia Mono">
<DataGrid.Resources>
<Style x:Key="CellText" TargetType="TextBlock"><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
<Style x:Key="NameCellText" TargetType="TextBlock" BasedOn="{StaticResource CellText}"><Setter Property="Margin" Value="10,0,0,0"/></Style>
<Style x:Key="CenterCellText" TargetType="TextBlock" BasedOn="{StaticResource CellText}"><Setter Property="HorizontalAlignment" Value="Center"/></Style>
<Style x:Key="CenterHeader" TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#0C181A"/><Setter Property="Foreground" Value="#789291"/><Setter Property="BorderBrush" Value="#254547"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="Padding" Value="0"/><Setter Property="FontWeight" Value="Normal"/><Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
<Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#0C181A"/><Setter Property="Foreground" Value="#789291"/><Setter Property="BorderBrush" Value="#254547"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="Padding" Value="12,8"/><Setter Property="FontWeight" Value="Normal"/></Style>
<Style TargetType="DataGridCell"><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,0"/><Setter Property="VerticalContentAlignment" Value="Stretch"/><Setter Property="ToolTip" Value="{Binding Path}"/><Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#17453F"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></Style.Triggers></Style>
</DataGrid.Resources><DataGrid.Columns>
<DataGridTextColumn Header="NAME" ElementStyle="{StaticResource NameCellText}" Binding="{Binding Name}" SortMemberPath="Name" Width="*"/>
<DataGridTextColumn Header="TYPE" HeaderStyle="{StaticResource CenterHeader}" ElementStyle="{StaticResource CenterCellText}" Binding="{Binding Type}" SortMemberPath="Type" Width="110"/>
<DataGridTextColumn Header="SIZE" HeaderStyle="{StaticResource CenterHeader}" ElementStyle="{StaticResource CenterCellText}" Binding="{Binding Size}" SortMemberPath="SizeBytes" Width="110"/>
<DataGridTemplateColumn Header="ACTION" HeaderStyle="{StaticResource CenterHeader}" Width="105"><DataGridTemplateColumn.CellTemplate><DataTemplate><Button Content="REMOVE" Tag="{Binding Id}" Margin="0" Padding="10,0" VerticalAlignment="Stretch" HorizontalAlignment="Stretch" ToolTip="Stop sharing this item. The file will not be deleted."/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
</DataGrid.Columns></DataGrid></Grid></Border>
  </Grid>
  <!-- server details -->
  <Border Grid.Row="2" Margin="20,0" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Background="#B0081213"><Grid Margin="20,14"><Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="SERVER" FontFamily="Cascadia Mono" Foreground="{StaticResource Accent}"/><StackPanel Orientation="Horizontal" Margin="0,15,0,0"><Ellipse Width="24" Height="24" Fill="{StaticResource Accent}" Margin="0,0,14,0"/><StackPanel><TextBlock Text="ONLINE" FontFamily="Cascadia Mono" FontSize="18" Foreground="{StaticResource Accent}"/></StackPanel></StackPanel></StackPanel><Grid Grid.Column="1"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Address (IPv4)" Foreground="#78908E"/><TextBlock x:Name="AddressText" Text="Starting..." FontFamily="Cascadia Mono" Margin="0,5,0,12"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="Shared items" Foreground="#78908E"/><TextBlock x:Name="CountText" Text="0" FontFamily="Cascadia Mono" Margin="0,5,0,12"/></StackPanel></Grid><StackPanel Grid.Column="2" VerticalAlignment="Center"><Button x:Name="ClearButton" Content="CLEAR SHARED ITEMS" Height="38"/></StackPanel></Grid></Border>
  <Grid Grid.Row="3" Background="#091314"><TextBlock x:Name="FooterText" Text="■  READY   |   Waiting for media..." Margin="22,10" FontFamily="Cascadia Mono" FontSize="11" Foreground="#86A09D"/><TextBlock Text="LOCAL  |  PRIVATE  |  NO CLOUD" HorizontalAlignment="Right" Margin="0,10,20,0" FontFamily="Cascadia Mono" FontSize="10" Foreground="#617875"/></Grid>
 </Grid></Border>
</Window>
'@

# Bind named controls from XAML and create the server instance.
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$names = 'TitleBar','MinButton','CloseButton','DropZone','BrowseButton','MediaList','ItemsHeader','SizeHeader','AddressText','CountText','ClearButton','FooterText'
foreach($n in $names){ Set-Variable -Name $n -Value $window.FindName($n) }
$server = New-Object EcoDlnaServerScan
if ($null -eq $server) {
    [System.Windows.MessageBox]::Show("The server engine could not be created.", "Eco Media Server")
    return
}

# UI helpers for formatting, refreshing the catalog, and adding files or folders.
function Format-Bytes([long]$n) { if($n -ge 1GB){'{0:N1} GB' -f ($n/1GB)} elseif($n -ge 1MB){'{0:N1} MB' -f ($n/1MB)} elseif($n -ge 1KB){'{0:N1} KB' -f ($n/1KB)} else{"$n B"} }
function Refresh-List {
    $MediaList.Items.Clear()
    foreach($i in $server.Snapshot()) {$type=if($i.Mime.StartsWith('video/')){'VIDEO'}elseif($i.Mime.StartsWith('audio/')){'AUDIO'}elseif($i.Mime.StartsWith('image/')){'IMAGE'}else{'OTHER'};[void]$MediaList.Items.Add([pscustomobject]@{Id=$i.Id;Name=[IO.Path]::GetFileName($i.Path);Type=$type;Size=(Format-Bytes $i.Length);SizeBytes=[long]$i.Length;Path=$i.Path})}
    $ItemsHeader.Text="SHARED MEDIA ( $($server.ItemCount) )";$SizeHeader.Text="TOTAL: $(Format-Bytes $server.TotalBytes)";$CountText.Text="$($server.ItemCount) ($(Format-Bytes $server.TotalBytes))"
}
function Add-Path([string]$p) {
    if([IO.File]::Exists($p)){ $server.Add($p) }
    elseif([IO.Directory]::Exists($p)){ Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue | Where-Object Extension -match '^\.(mkv|mp4|m4v|avi|mov|mpg|mpeg|ts|m2ts|mp3|flac|wav|jpg|jpeg|png)$' | ForEach-Object {$server.Add($_.FullName)} }
}

# Start the server and display its address when startup succeeds.
try {
    $server.Start(5080)
}
catch {
    [System.Windows.MessageBox]::Show(
        "The media server could not start.`n`n$($_.Exception.GetType().FullName)`n$($_.Exception.Message)`n`nLine: $($_.InvocationInfo.ScriptLineNumber)",
        "Eco Media Server"
    )
}
if ($null -ne $AddressText -and $server.Running) {
    $AddressText.Text = $server.Address
}
# Wire window controls, file selection, drag-and-drop, and media-list actions.
$TitleBar.Add_MouseLeftButtonDown({ if($_.ClickCount -eq 2){if($window.WindowState -eq 'Maximized'){$window.WindowState='Normal'}else{$window.WindowState='Maximized'}}else{$window.DragMove()} })
$MinButton.Add_Click({$window.WindowState='Minimized'}); $CloseButton.Add_Click({$window.Close()})
$BrowseButton.Add_Click({ $d=New-Object Microsoft.Win32.OpenFileDialog; $d.Multiselect=$true; $d.Filter='Media files|*.mkv;*.mp4;*.m4v;*.avi;*.mov;*.mpg;*.mpeg;*.ts;*.m2ts;*.mp3;*.flac;*.wav;*.jpg;*.jpeg;*.png|All files|*.*'; if($d.ShowDialog()){$d.FileNames|%{Add-Path $_};Refresh-List} })
$window.Add_DragOver({$_.Effects='Copy';$_.Handled=$true;$DropZone.Background='#CC12302B'})
$window.Add_DragLeave({$DropZone.Background='#97101D1F'})
$window.Add_Drop({$DropZone.Background='#97101D1F'; if($_.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){foreach($p in $_.Data.GetData([Windows.DataFormats]::FileDrop)){Add-Path $p};Refresh-List}})
$MediaList.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$e);$button=$e.OriginalSource;if($button -is [Windows.Controls.Button] -and $button.Tag){$server.Remove([string]$button.Tag);Refresh-List;$e.Handled=$true}})
$MediaList.Add_KeyDown({if($_.Key -eq [Windows.Input.Key]::Delete){$ids=@($MediaList.SelectedItems|ForEach-Object{$_.Id});foreach($id in $ids){$server.Remove([string]$id)};if($ids.Count){Refresh-List};$_.Handled=$true}})
$ClearButton.Add_Click({if($server.ItemCount -eq 0){return};$answer=[System.Windows.MessageBox]::Show("Stop sharing all $($server.ItemCount) items?`n`nFiles on disk will not be deleted.",'Eco Media Server',[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Question);if($answer -eq [System.Windows.MessageBoxResult]::Yes){foreach($i in $server.Snapshot()){$server.Remove($i.Id)};Refresh-List}})
# Refresh the footer log periodically and stop background services on window close.
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromMilliseconds(700); $timer.Add_Tick({$l=$server.DrainLogs();if($l.Count){$FooterText.Text='■  '+$l[-1]}});$timer.Start()
$window.Add_Closing({$timer.Stop();$server.Dispose()})
[void]$window.ShowDialog()