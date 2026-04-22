unit MCPServer.SessionManager;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  System.JSON;

type
  TMCPClientElicitationCapabilities = record
    FormSupported: Boolean;
    URLSupported: Boolean;
  end;

  TMCPPendingClientRequest = class
  private
    FWaitHandle: TEvent;
    FResponse: TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetResponse(const Response: TJSONObject);
    function WaitForResponse(TimeoutMS: Cardinal; out Response: TJSONObject): Boolean;
  end;

  TMCPSessionState = class
  private
    FLock: TCriticalSection;
    FOutgoingMessages: TQueue<string>;
    FOutgoingEvent: TEvent;
    FPendingRequests: TDictionary<string, TMCPPendingClientRequest>;
    FCompletedElicitations: TDictionary<string, Boolean>;
    FCapabilities: TMCPClientElicitationCapabilities;
    FSessionID: string;
    class function CloneJSONObject(const Value: TJSONObject): TJSONObject; static;
  public
    constructor Create(const SessionID: string);
    destructor Destroy; override;
    procedure UpdateCapabilities(FormSupported, URLSupported: Boolean);
    function GetCapabilities: TMCPClientElicitationCapabilities;
    procedure EnqueueOutgoingMessage(const Message: string);
    function WaitForOutgoingMessage(TimeoutMS: Cardinal; out Message: string): Boolean;
    procedure AddPendingRequest(const RequestID: string; PendingRequest: TMCPPendingClientRequest);
    procedure RemovePendingRequest(const RequestID: string);
    function CompletePendingRequest(const RequestID: string; const Response: TJSONObject): Boolean;
    procedure MarkElicitationCompleted(const ElicitationID: string);
    function IsElicitationCompleted(const ElicitationID: string): Boolean;
    property SessionID: string read FSessionID;
  end;

  TMCPSessionManager = class
  strict private
    class var FInstance: TMCPSessionManager;
    FLock: TCriticalSection;
    FSessions: TObjectDictionary<string, TMCPSessionState>;
    class function CloneJSONObject(const Value: TJSONObject): TJSONObject; static;
    class function CreateRequestID: string; static;
    function GetSession(const SessionID: string): TMCPSessionState;
  public
    constructor Create;
    destructor Destroy; override;
    class function Instance: TMCPSessionManager; static;
    class procedure FinalizeInstance; static;
    function HasSession(const SessionID: string): Boolean;
    function EnsureSession(const SessionID: string): TMCPSessionState;
    procedure StoreClientCapabilities(const SessionID: string; FormSupported, URLSupported: Boolean);
    function GetClientCapabilities(const SessionID: string; out Capabilities: TMCPClientElicitationCapabilities): Boolean;
    function SendClientRequestAndWait(const SessionID, MethodName: string; const Params: TJSONObject; TimeoutMS: Cardinal): TJSONObject;
    procedure EnqueueNotification(const SessionID, MethodName: string; const Params: TJSONObject);
    function WaitForNextOutboundMessage(const SessionID: string; TimeoutMS: Cardinal; out Message: string): Boolean;
    function ProcessClientResponse(const SessionID: string; const ResponseObj: TJSONObject): Boolean;
    procedure MarkElicitationCompleted(const SessionID, ElicitationID: string);
    function IsElicitationCompleted(const SessionID, ElicitationID: string): Boolean;
  end;

implementation

{ TMCPPendingClientRequest }

constructor TMCPPendingClientRequest.Create;
begin
  inherited Create;
  FWaitHandle := TEvent.Create(nil, True, False, '');
  FResponse := nil;
end;

destructor TMCPPendingClientRequest.Destroy;
begin
  FResponse.Free;
  FWaitHandle.Free;
  inherited;
end;

procedure TMCPPendingClientRequest.SetResponse(const Response: TJSONObject);
begin
  FResponse.Free;
  FResponse := TMCPSessionState.CloneJSONObject(Response);
  FWaitHandle.SetEvent;
end;

function TMCPPendingClientRequest.WaitForResponse(TimeoutMS: Cardinal; out Response: TJSONObject): Boolean;
begin
  Result := FWaitHandle.WaitFor(TimeoutMS) = wrSignaled;
  if Result and Assigned(FResponse) then
    Response := TMCPSessionState.CloneJSONObject(FResponse)
  else
    Response := nil;
end;

{ TMCPSessionState }

constructor TMCPSessionState.Create(const SessionID: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FOutgoingMessages := TQueue<string>.Create;
  FOutgoingEvent := TEvent.Create(nil, True, False, '');
  FPendingRequests := TDictionary<string, TMCPPendingClientRequest>.Create;
  FCompletedElicitations := TDictionary<string, Boolean>.Create;
  FSessionID := SessionID;
end;

destructor TMCPSessionState.Destroy;
begin
  for var PendingRequest in FPendingRequests.Values do
    PendingRequest.Free;
  FPendingRequests.Free;
  FCompletedElicitations.Free;
  FOutgoingEvent.Free;
  FOutgoingMessages.Free;
  FLock.Free;
  inherited;
end;

class function TMCPSessionState.CloneJSONObject(const Value: TJSONObject): TJSONObject;
begin
  Result := nil;
  if Assigned(Value) then
    Result := TJSONObject.ParseJSONValue(Value.ToJSON) as TJSONObject;
end;

procedure TMCPSessionState.UpdateCapabilities(FormSupported, URLSupported: Boolean);
begin
  FLock.Acquire;
  try
    FCapabilities.FormSupported := FormSupported;
    FCapabilities.URLSupported := URLSupported;
  finally
    FLock.Release;
  end;
end;

function TMCPSessionState.GetCapabilities: TMCPClientElicitationCapabilities;
begin
  FLock.Acquire;
  try
    Result := FCapabilities;
  finally
    FLock.Release;
  end;
end;

procedure TMCPSessionState.EnqueueOutgoingMessage(const Message: string);
begin
  FLock.Acquire;
  try
    FOutgoingMessages.Enqueue(Message);
    FOutgoingEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TMCPSessionState.WaitForOutgoingMessage(TimeoutMS: Cardinal; out Message: string): Boolean;
begin
  Message := '';
  Result := FOutgoingEvent.WaitFor(TimeoutMS) = wrSignaled;
  if not Result then
    Exit;

  FLock.Acquire;
  try
    if FOutgoingMessages.Count = 0 then
    begin
      FOutgoingEvent.ResetEvent;
      Result := False;
      Exit;
    end;

    Message := FOutgoingMessages.Dequeue;
    if FOutgoingMessages.Count = 0 then
      FOutgoingEvent.ResetEvent;
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TMCPSessionState.AddPendingRequest(const RequestID: string; PendingRequest: TMCPPendingClientRequest);
begin
  FLock.Acquire;
  try
    FPendingRequests.Add(RequestID, PendingRequest);
  finally
    FLock.Release;
  end;
end;

procedure TMCPSessionState.RemovePendingRequest(const RequestID: string);
begin
  FLock.Acquire;
  try
    FPendingRequests.Remove(RequestID);
  finally
    FLock.Release;
  end;
end;

function TMCPSessionState.CompletePendingRequest(const RequestID: string; const Response: TJSONObject): Boolean;
var
  PendingRequest: TMCPPendingClientRequest;
begin
  FLock.Acquire;
  try
    Result := FPendingRequests.TryGetValue(RequestID, PendingRequest);
    if Result then
      PendingRequest.SetResponse(Response);
  finally
    FLock.Release;
  end;
end;

procedure TMCPSessionState.MarkElicitationCompleted(const ElicitationID: string);
begin
  FLock.Acquire;
  try
    FCompletedElicitations.AddOrSetValue(ElicitationID, True);
  finally
    FLock.Release;
  end;
end;

function TMCPSessionState.IsElicitationCompleted(const ElicitationID: string): Boolean;
begin
  FLock.Acquire;
  try
    Result := FCompletedElicitations.ContainsKey(ElicitationID);
  finally
    FLock.Release;
  end;
end;

{ TMCPSessionManager }

constructor TMCPSessionManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSessions := TObjectDictionary<string, TMCPSessionState>.Create([doOwnsValues]);
end;

destructor TMCPSessionManager.Destroy;
begin
  FSessions.Free;
  FLock.Free;
  inherited;
end;

class function TMCPSessionManager.Instance: TMCPSessionManager;
begin
  if not Assigned(FInstance) then
    FInstance := TMCPSessionManager.Create;
  Result := FInstance;
end;

class procedure TMCPSessionManager.FinalizeInstance;
begin
  FInstance.Free;
  FInstance := nil;
end;

class function TMCPSessionManager.CloneJSONObject(const Value: TJSONObject): TJSONObject;
begin
  Result := TMCPSessionState.CloneJSONObject(Value);
end;

class function TMCPSessionManager.CreateRequestID: string;
begin
  Result := 'server-' + TGuid.NewGuid.ToString;
end;

function TMCPSessionManager.GetSession(const SessionID: string): TMCPSessionState;
begin
  Result := nil;
  FLock.Acquire;
  try
    FSessions.TryGetValue(SessionID, Result);
  finally
    FLock.Release;
  end;
end;

function TMCPSessionManager.HasSession(const SessionID: string): Boolean;
begin
  Result := Assigned(GetSession(SessionID));
end;

function TMCPSessionManager.EnsureSession(const SessionID: string): TMCPSessionState;
begin
  if SessionID = '' then
    raise Exception.Create('Session ID is required');

  FLock.Acquire;
  try
    if not FSessions.TryGetValue(SessionID, Result) then
    begin
      Result := TMCPSessionState.Create(SessionID);
      FSessions.Add(SessionID, Result);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TMCPSessionManager.StoreClientCapabilities(const SessionID: string; FormSupported, URLSupported: Boolean);
begin
  EnsureSession(SessionID).UpdateCapabilities(FormSupported, URLSupported);
end;

function TMCPSessionManager.GetClientCapabilities(const SessionID: string;
  out Capabilities: TMCPClientElicitationCapabilities): Boolean;
var
  Session: TMCPSessionState;
begin
  Session := GetSession(SessionID);
  Result := Assigned(Session);
  if Result then
    Capabilities := Session.GetCapabilities
  else
  begin
    Capabilities.FormSupported := False;
    Capabilities.URLSupported := False;
  end;
end;

function TMCPSessionManager.SendClientRequestAndWait(const SessionID, MethodName: string;
  const Params: TJSONObject; TimeoutMS: Cardinal): TJSONObject;
var
  Session: TMCPSessionState;
  RequestID: string;
  PendingRequest: TMCPPendingClientRequest;
  RequestJSON: TJSONObject;
begin
  Result := nil;

  Session := EnsureSession(SessionID);
  RequestID := CreateRequestID;
  PendingRequest := TMCPPendingClientRequest.Create;
  RequestJSON := TJSONObject.Create;
  try
    RequestJSON.AddPair('jsonrpc', '2.0');
    RequestJSON.AddPair('id', RequestID);
    RequestJSON.AddPair('method', MethodName);
    if Assigned(Params) then
      RequestJSON.AddPair('params', CloneJSONObject(Params));

    Session.AddPendingRequest(RequestID, PendingRequest);
    Session.EnqueueOutgoingMessage(RequestJSON.ToJSON);

    if not PendingRequest.WaitForResponse(TimeoutMS, Result) then
      raise Exception.CreateFmt('Timed out waiting for client response to %s', [MethodName]);
  finally
    Session.RemovePendingRequest(RequestID);
    PendingRequest.Free;
    RequestJSON.Free;
  end;
end;

procedure TMCPSessionManager.EnqueueNotification(const SessionID, MethodName: string; const Params: TJSONObject);
var
  Session: TMCPSessionState;
  NotificationJSON: TJSONObject;
begin
  Session := EnsureSession(SessionID);
  NotificationJSON := TJSONObject.Create;
  try
    NotificationJSON.AddPair('jsonrpc', '2.0');
    NotificationJSON.AddPair('method', MethodName);
    if Assigned(Params) then
      NotificationJSON.AddPair('params', CloneJSONObject(Params));
    Session.EnqueueOutgoingMessage(NotificationJSON.ToJSON);
  finally
    NotificationJSON.Free;
  end;
end;

function TMCPSessionManager.WaitForNextOutboundMessage(const SessionID: string;
  TimeoutMS: Cardinal; out Message: string): Boolean;
var
  Session: TMCPSessionState;
begin
  Session := GetSession(SessionID);
  if not Assigned(Session) then
  begin
    Message := '';
    Exit(False);
  end;

  Result := Session.WaitForOutgoingMessage(TimeoutMS, Message);
end;

function TMCPSessionManager.ProcessClientResponse(const SessionID: string; const ResponseObj: TJSONObject): Boolean;
var
  Session: TMCPSessionState;
  ResponseID: TJSONValue;
  RequestID: string;
begin
  Result := False;
  Session := GetSession(SessionID);
  if not Assigned(Session) then
    Exit;

  ResponseID := ResponseObj.GetValue('id');
  if not Assigned(ResponseID) then
    Exit;

  RequestID := ResponseID.Value;
  if RequestID = '' then
    Exit;

  Result := Session.CompletePendingRequest(RequestID, ResponseObj);
end;

procedure TMCPSessionManager.MarkElicitationCompleted(const SessionID, ElicitationID: string);
begin
  EnsureSession(SessionID).MarkElicitationCompleted(ElicitationID);
end;

function TMCPSessionManager.IsElicitationCompleted(const SessionID, ElicitationID: string): Boolean;
var
  Session: TMCPSessionState;
begin
  Session := GetSession(SessionID);
  Result := Assigned(Session) and Session.IsElicitationCompleted(ElicitationID);
end;

initialization

finalization
  TMCPSessionManager.FinalizeInstance;

end.