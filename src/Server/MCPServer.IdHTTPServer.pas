unit MCPServer.IdHTTPServer;

interface

// TaurusTLS provides OpenSSL 3.x support with modern ECDHE cipher suites
// Install via GetIt Package Manager: Search for "TaurusTLS" or get from https://github.com/JPeterMugaas/TaurusTLS
{.$DEFINE USE_TAURUS_TLS}  // Comment this line to use standard Indy SSL (OpenSSL 1.0.2)

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.IOUtils,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal,
  IdGlobalProtocols,
  {$IFDEF USE_TAURUS_TLS}
  TaurusTLS,
  {$ELSE}
  IdSSLOpenSSL,
  {$ENDIF}
  IdServerIOHandler,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.JsonRpcProcessor;

type
  TMCPIdHTTPServer = class(TComponent)
  private
    FHTTPServer: TIdHTTPServer;
    {$IFDEF USE_TAURUS_TLS}
    FSSLHandler: TTaurusTLSServerIOHandler;
    {$ELSE}
    FSSLHandler: TIdServerIOHandlerSSLOpenSSL;
    {$ENDIF}
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
    FPort: Word;
    FActive: Boolean;
    FSettings: TMCPSettings;
    FEventIDCounter: Int64;
    procedure ConfigureSSL;
    procedure HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
    procedure HandleHTTPRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    function VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo): Boolean;
    procedure HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
    procedure HandleGetRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePostRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePostRequestSSE(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; const SessionID: string);
    procedure HandlePostRequestJSON(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; const SessionID: string);
    function GetNextEventID: string;
    function AcceptsSSE(const AcceptHeader: string): Boolean;
    procedure PrepareSSEHeaders(ResponseInfo: TIdHTTPResponseInfo; const SessionID: string);
    function BuildSSEPayload(const JSONPayload: string): string;
    function TryProcessClientMessages(const SessionID: string; JSONRequest: TJSONValue): Boolean;
  public
    constructor Create(Owner: TComponent); override;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Port: Word read FPort write FPort;
    property Active: Boolean read FActive;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry write FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager write FCoreManager;
    property Settings: TMCPSettings read FSettings write FSettings;
  end;

implementation

uses
  MCPServer.Resource.Server,
  MCPServer.CoreManager,
  MCPServer.Logger,
  MCPServer.SessionManager;

const
  DEFAULT_MCP_PORT = 3000;
  SSE_WAIT_TIMEOUT_MS = 30000;

  HTTP_OK = 200;
  HTTP_ACCEPTED = 202;
  HTTP_NO_CONTENT = 204;
  HTTP_BAD_REQUEST = 400;
  HTTP_NOT_FOUND = 404;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_FORBIDDEN = 403;

  CORS_MAX_AGE = 86400;

  SSE_EVENT_PREFIX = 'event: ';
  SSE_DATA_PREFIX = 'data: ';
  SSE_ID_PREFIX = 'id: ';
  SSE_MESSAGE_TERMINATOR = #10#10;
  SSE_COMMENT_PREFIX = ': ';

constructor TMCPIdHTTPServer.Create(Owner: TComponent);
begin
  inherited Create(Owner);
  FPort := DEFAULT_MCP_PORT;
  FActive := False;
  FEventIDCounter := 0;
  FJsonRpcProcessor := nil;

  FHTTPServer := TIdHTTPServer.Create(Self);
  FHTTPServer.KeepAlive := True;
  FHTTPServer.OnCommandGet := HandleHTTPRequest;
  FHTTPServer.OnCommandOther := HandleHTTPRequest;
  FHTTPServer.OnQuerySSLPort := HandleQuerySSLPort;
  FSSLHandler := nil;
end;

destructor TMCPIdHTTPServer.Destroy;
begin
  if FActive then
    Stop;
  FHTTPServer.Free;
  if Assigned(FSSLHandler) then
    FSSLHandler.Free;
  FJsonRpcProcessor.Free;
  inherited;
end;

procedure TMCPIdHTTPServer.Start;
begin
  if FActive then
    Exit;

  if not Assigned(FManagerRegistry) then
    raise Exception.Create('Manager registry not assigned');

  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(FManagerRegistry);

  if Assigned(FSettings) then
  begin
    FPort := Word(FSettings.Port);
    if FSettings.SSLEnabled then
      ConfigureSSL;
  end;

  FHTTPServer.DefaultPort := FPort;
  FHTTPServer.Active := True;
  FActive := True;

  TLogger.Info('MCP Server started on ' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort));
end;

procedure TMCPIdHTTPServer.Stop;
begin
  if not FActive then
    Exit;

  FHTTPServer.Active := False;
  FActive := False;
  TLogger.Info('MCP Server stopped');
end;

procedure TMCPIdHTTPServer.HandleHTTPRequest(Context: TIdContext;
  RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  TServerStatusResource.ConnectionOpened;
  try
    TServerStatusResource.IncrementRequestCount;

    if not VerifyAndSetCORSHeaders(RequestInfo, ResponseInfo) then
      Exit;

    if RequestInfo.Document <> FSettings.Endpoint then
    begin
      ResponseInfo.ResponseNo := HTTP_NOT_FOUND;
      ResponseInfo.ResponseText := 'Not Found';
      Exit;
    end;

    if RequestInfo.Command = 'OPTIONS' then
      HandleOptionsRequest(ResponseInfo)
    else if RequestInfo.CommandType = hcGET then
      HandleGetRequest(RequestInfo, ResponseInfo)
    else if RequestInfo.CommandType = hcPOST then
      HandlePostRequest(RequestInfo, ResponseInfo)
    else
    begin
      ResponseInfo.ResponseNo := HTTP_METHOD_NOT_ALLOWED;
      ResponseInfo.ResponseText := 'Method Not Allowed';
    end;
  finally
    TServerStatusResource.ConnectionClosed;
  end;
end;

function TMCPIdHTTPServer.VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo): Boolean;
begin
  Result := True;

  if not Assigned(FSettings) or not FSettings.CorsEnabled then
    Exit;

  var Origin := RequestInfo.RawHeaders.Values['Origin'];
  var AllowedOrigin: string := '*';

  if (FSettings.CorsAllowedOrigins <> '*') and (Origin <> '') then
  begin
    var OriginsList := TStringList.Create;
    try
      OriginsList.CommaText := FSettings.CorsAllowedOrigins;
      var Found := False;

      for var CurrentOrigin in OriginsList do
      begin
        if SameText(Trim(CurrentOrigin), Origin) then
        begin
          AllowedOrigin := Origin;
          Found := True;
          Break;
        end;
      end;

      if not Found then
      begin
        Result := False;
        ResponseInfo.ResponseNo := HTTP_FORBIDDEN;
        ResponseInfo.ResponseText := 'Forbidden - Origin not allowed';
        TLogger.Info('CORS blocked origin: ' + Origin);
        Exit;
      end;
    finally
      OriginsList.Free;
    end;
  end;

  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := AllowedOrigin;
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'POST, GET, OPTIONS';
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] :=
    'Content-Type, Accept, Mcp-Session-Id';
  ResponseInfo.CustomHeaders.Values['Access-Control-Max-Age'] := CORS_MAX_AGE.ToString;
end;

procedure TMCPIdHTTPServer.HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
begin
  ResponseInfo.ResponseNo := HTTP_OK;
  ResponseInfo.ResponseText := 'OK';
end;

procedure TMCPIdHTTPServer.PrepareSSEHeaders(ResponseInfo: TIdHTTPResponseInfo;
  const SessionID: string);
begin
  ResponseInfo.ContentType := 'text/event-stream';
  ResponseInfo.CharSet := 'utf-8';
  ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
  ResponseInfo.CustomHeaders.Values['X-Accel-Buffering'] := 'no';
  if SessionID <> '' then
    ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;
end;

function TMCPIdHTTPServer.BuildSSEPayload(const JSONPayload: string): string;
begin
  Result := SSE_ID_PREFIX + GetNextEventID + #10 +
            SSE_EVENT_PREFIX + 'message' + #10 +
            SSE_DATA_PREFIX + JSONPayload + SSE_MESSAGE_TERMINATOR;
end;

procedure TMCPIdHTTPServer.HandleGetRequest(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
var
  AcceptHeader: string;
  SessionID: string;
  OutboundMessage: string;
begin
  AcceptHeader := RequestInfo.RawHeaders.Values['Accept'];

  if AcceptsSSE(AcceptHeader) then
  begin
    SessionID := RequestInfo.RawHeaders.Values['Mcp-Session-Id'];
    if (SessionID = '') or not TMCPSessionManager.Instance.HasSession(SessionID) then
    begin
      ResponseInfo.ResponseNo := HTTP_BAD_REQUEST;
      ResponseInfo.ResponseText := 'A valid Mcp-Session-Id header is required for SSE polling';
      Exit;
    end;

    PrepareSSEHeaders(ResponseInfo, SessionID);
    OutboundMessage := '';
    if TMCPSessionManager.Instance.WaitForNextOutboundMessage(SessionID, SSE_WAIT_TIMEOUT_MS, OutboundMessage) then
    begin
      ResponseInfo.ContentText := BuildSSEPayload(OutboundMessage);
      TLogger.Info('Delivered outbound SSE message for session ' + SessionID);
    end
    else
      ResponseInfo.ContentText := SSE_COMMENT_PREFIX + 'keepalive' + SSE_MESSAGE_TERMINATOR;

    ResponseInfo.ResponseNo := HTTP_OK;
    Exit;
  end;

  TLogger.Info('Received GET request - returning endpoint info');
  ResponseInfo.ContentType := 'application/json';
  ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
  ResponseInfo.ContentText := '{"url": "' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort) +
    FSettings.Endpoint + '", "transport": "' + FSettings.Protocol + '"}';
  ResponseInfo.ResponseNo := HTTP_OK;
end;

procedure TMCPIdHTTPServer.HandlePostRequest(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
begin
  var RequestBody := '';
  if Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0) then
  begin
    RequestInfo.PostStream.Position := 0;
    RequestBody := ReadStringFromStream(RequestInfo.PostStream, -1, IndyTextEncoding_UTF8);
  end;

  TLogger.Info('Request: ' + RequestBody);

  var SessionID := RequestInfo.RawHeaders.Values['Mcp-Session-Id'];
  if SessionID <> '' then
    TLogger.Info('Session ID from header: ' + SessionID);

  var AcceptHeader := RequestInfo.RawHeaders.Values['Accept'];
  var JSONRequest: TJSONValue := nil;
  try
    JSONRequest := TJSONObject.ParseJSONValue(RequestBody);

    if Assigned(JSONRequest) and TryProcessClientMessages(SessionID, JSONRequest) then
    begin
      TLogger.Info('Processed client response message, returning 202 Accepted');
      ResponseInfo.ResponseNo := HTTP_ACCEPTED;
      if SessionID <> '' then
        ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;
      Exit;
    end;

    var lIsInitializeMethod := false;
    if assigned(JsonRequest) and (JSONRequest is TJsonObject) then
      lIsInitializeMethod := TJSONObject(JSONRequest).GetValue('method').Value = 'initialize';

    if AcceptsSSE(AcceptHeader) and not lIsInitializeMethod then
      HandlePostRequestSSE(RequestInfo, ResponseInfo, RequestBody, SessionID)
    else
      HandlePostRequestJSON(RequestInfo, ResponseInfo, RequestBody, SessionID);
  finally
    JSONRequest.Free;
  end;
end;

procedure TMCPIdHTTPServer.ConfigureSSL;
begin
  if not TFile.Exists(FSettings.SSLCertFile) then
  begin
    TLogger.Error('SSL Certificate file not found: ' + FSettings.SSLCertFile);
    raise Exception.Create('SSL Certificate file not found: ' + FSettings.SSLCertFile);
  end;

  if not TFile.Exists(FSettings.SSLKeyFile) then
  begin
    TLogger.Error('SSL Key file not found: ' + FSettings.SSLKeyFile);
    raise Exception.Create('SSL Key file not found: ' + FSettings.SSLKeyFile);
  end;

  {$IFDEF USE_TAURUS_TLS}
  FSSLHandler := TTaurusTLSServerIOHandler.Create(Self);
  FSSLHandler.DefaultCert.PublicKey := FSettings.SSLCertFile;
  FSSLHandler.DefaultCert.PrivateKey := FSettings.SSLKeyFile;
  {$ELSE}
  FSSLHandler := TIdServerIOHandlerSSLOpenSSL.Create(Self);
  FSSLHandler.SSLOptions.CertFile := FSettings.SSLCertFile;
  FSSLHandler.SSLOptions.KeyFile := FSettings.SSLKeyFile;

  if (FSettings.SSLRootCertFile <> '') and TFile.Exists(FSettings.SSLRootCertFile) then
    FSSLHandler.SSLOptions.RootCertFile := FSettings.SSLRootCertFile;

  FSSLHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLHandler.SSLOptions.SSLVersions := [sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2];
  FSSLHandler.SSLOptions.Mode := sslmServer;
  {$ENDIF}

  FHTTPServer.IOHandler := FSSLHandler;

  TLogger.Info('SSL configured successfully');
  TLogger.Info('Certificate: ' + FSettings.SSLCertFile);
  TLogger.Info('Private Key: ' + FSettings.SSLKeyFile);
  if FSettings.SSLRootCertFile <> '' then
    TLogger.Info('Root Certificate: ' + FSettings.SSLRootCertFile);
end;

procedure TMCPIdHTTPServer.HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
begin
  VUseSSL := FSettings.SSLEnabled and (APort = FPort);
end;

function TMCPIdHTTPServer.GetNextEventID: string;
begin
  Inc(FEventIDCounter);
  Result := IntToStr(FEventIDCounter);
end;

function TMCPIdHTTPServer.AcceptsSSE(const AcceptHeader: string): Boolean;
begin
  Result := Pos('text/event-stream', AcceptHeader) > 0;
end;

function TMCPIdHTTPServer.TryProcessClientMessages(const SessionID: string;
  JSONRequest: TJSONValue): Boolean;
begin
  Result := False;

  if JSONRequest is TJSONObject then
  begin
    var RequestObject := JSONRequest as TJSONObject;
    if Assigned(RequestObject.GetValue('result')) or Assigned(RequestObject.GetValue('error')) then
    begin
      if SessionID = '' then
        raise Exception.Create('Mcp-Session-Id header is required for client responses');
      Result := TMCPSessionManager.Instance.ProcessClientResponse(SessionID, RequestObject);
    end;
    Exit;
  end;

  if JSONRequest is TJSONArray then
  begin
    Result := True;
    for var I := 0 to (JSONRequest as TJSONArray).Count - 1 do
    begin
      if not TryProcessClientMessages(SessionID, (JSONRequest as TJSONArray).Items[I]) then
      begin
        Result := False;
        Break;
      end;
    end;
  end;
end;

procedure TMCPIdHTTPServer.HandlePostRequestSSE(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; const SessionID: string);
begin
  TLogger.Info('Handling POST request with SSE response');
  PrepareSSEHeaders(ResponseInfo, SessionID);

  var JSONResponse := FJsonRpcProcessor.ProcessRequest(RequestBody, SessionID);
  if JSONResponse <> '' then
    ResponseInfo.ContentText := BuildSSEPayload(JSONResponse)
  else
    ResponseInfo.ContentText := SSE_COMMENT_PREFIX + 'accepted' + SSE_MESSAGE_TERMINATOR;

  ResponseInfo.ResponseNo := HTTP_OK;
end;

procedure TMCPIdHTTPServer.HandlePostRequestJSON(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo; const RequestBody: string; const SessionID: string);
begin
  TLogger.Info('Handling POST request with JSON response');

  var ResponseBody := FJsonRpcProcessor.ProcessRequest(RequestBody, SessionID);
  if ResponseBody = '' then
  begin
    ResponseInfo.ResponseNo := HTTP_NO_CONTENT;
    if SessionID <> '' then
      ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;
    Exit;
  end;

  ResponseInfo.ContentType := 'application/json';
  ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';

  if (SessionID = '') and (Pos('"sessionId"', ResponseBody) > 0) then
  begin
    var ResponseJSON := TJSONObject.ParseJSONValue(ResponseBody) as TJSONObject;
    try
      var ResultObj := ResponseJSON.GetValue('result') as TJSONObject;
      if Assigned(ResultObj) then
      begin
        var SessionValue := ResultObj.GetValue('sessionId');
        if Assigned(SessionValue) then
          ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionValue.Value;
      end;
    finally
      ResponseJSON.Free;
    end;
  end
  else if SessionID <> '' then
    ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionID;

  ResponseInfo.ContentStream := TStringStream.Create(ResponseBody, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
  ResponseInfo.ResponseNo := HTTP_OK;

  TLogger.Info('Response: ' + ResponseBody);
end;

end.