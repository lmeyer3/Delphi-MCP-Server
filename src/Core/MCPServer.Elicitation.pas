unit MCPServer.Elicitation;

interface

uses
  System.SysUtils,
  System.JSON;

type
  TMCPElicitationService = class
  strict private
    class function CurrentSessionID: string; static;
    class function CloneJSONObject(const Value: TJSONObject): TJSONObject; static;
    class procedure EnsureClientSupportsMode(const SessionID, Mode: string); static;
    class function SendElicitationRequest(const Params: TJSONObject; TimeoutMS: Cardinal): TJSONObject; static;
    class procedure ValidateSchemaProperty(const PropName: string; const PropSchema: TJSONObject); static;
    class function ExtractResultObject(const Response: TJSONObject): TJSONObject; static;
  public
    class procedure ValidateRequestedSchema(const RequestedSchema: TJSONObject); static;
    class function RequestForm(const Message: string; const RequestedSchema: TJSONObject; TimeoutMS: Cardinal = 300000): TJSONObject; static;
    class function RequestURL(const ElicitationID, URL, Message: string; TimeoutMS: Cardinal = 300000): TJSONObject; static;
    class procedure RaiseURLElicitationRequired(const ElicitationID, URL, Message: string); static;
    class procedure CompleteURLElicitation(const ElicitationID: string); static;
    class function IsURLElicitationCompleted(const ElicitationID: string): Boolean; static;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.SessionManager;

const
  MCP_ELICITATION_METHOD_CREATE = 'elicitation/create';
  MCP_ELICITATION_NOTIFICATION_COMPLETE = 'notifications/elicitation/complete';

class function TMCPElicitationService.CurrentSessionID: string;
begin
  Result := TMCPRequestContext.CurrentSessionID;
  if Result = '' then
    raise EMCPJsonRpcError.Create(JSONRPC_INTERNAL_ERROR,
      'Elicitation requires an active MCP session context.');
end;

class function TMCPElicitationService.CloneJSONObject(const Value: TJSONObject): TJSONObject;
begin
  Result := nil;
  if Assigned(Value) then
    Result := TJSONObject.ParseJSONValue(Value.ToJSON) as TJSONObject;
end;

class procedure TMCPElicitationService.EnsureClientSupportsMode(const SessionID, Mode: string);
begin
  var Capabilities: TMCPClientElicitationCapabilities;
  if not TMCPSessionManager.Instance.GetClientCapabilities(SessionID, Capabilities) then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'Client elicitation capabilities are not available for this session.');

  if SameText(Mode, 'form') and not Capabilities.FormSupported then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'The connected client does not support form elicitation.')
  else if SameText(Mode, 'url') and not Capabilities.URLSupported then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'The connected client does not support URL elicitation.');
end;

class function TMCPElicitationService.ExtractResultObject(const Response: TJSONObject): TJSONObject;
begin
  var ErrorObj := Response.GetValue('error') as TJSONObject;
  if Assigned(ErrorObj) then
  begin
    var ErrorCode := JSONRPC_INTERNAL_ERROR;
    var ErrorCodeValue := ErrorObj.GetValue('code');
    if Assigned(ErrorCodeValue) then
      ErrorCode := StrToIntDef(ErrorCodeValue.Value, JSONRPC_INTERNAL_ERROR);

    var ErrorMessage := 'Client returned an error.';
    var ErrorMessageValue := ErrorObj.GetValue('message');
    if Assigned(ErrorMessageValue) and (ErrorMessageValue.Value <> '') then
      ErrorMessage := ErrorMessageValue.Value;

    raise EMCPJsonRpcError.Create(ErrorCode, ErrorMessage,
      CloneJSONObject(ErrorObj.GetValue('data') as TJSONObject));
  end;

  Result := Response.GetValue('result') as TJSONObject;
  if not Assigned(Result) then
    raise EMCPJsonRpcError.Create(JSONRPC_INTERNAL_ERROR,
      'Client returned an elicitation response without a result object.');

  Result := CloneJSONObject(Result);

  var ActionValue := Result.GetValue('action');
  if not Assigned(ActionValue) then
    raise EMCPJsonRpcError.Create(JSONRPC_INTERNAL_ERROR,
      'Client returned an elicitation response without an action.');

  if not SameText(ActionValue.Value, 'accept') and
     not SameText(ActionValue.Value, 'decline') and
     not SameText(ActionValue.Value, 'cancel') then
    raise EMCPJsonRpcError.Create(JSONRPC_INTERNAL_ERROR,
      'Client returned an invalid elicitation action: ' + ActionValue.Value);
end;

class function TMCPElicitationService.SendElicitationRequest(const Params: TJSONObject;
  TimeoutMS: Cardinal): TJSONObject;
begin
  Result := nil;
  var SessionID := CurrentSessionID;
  var ModeValue := Params.GetValue('mode');
  var Mode := 'form';
  if Assigned(ModeValue) then
    Mode := ModeValue.Value;

  EnsureClientSupportsMode(SessionID, Mode);

  var Response := TMCPSessionManager.Instance.SendClientRequestAndWait(
    SessionID, MCP_ELICITATION_METHOD_CREATE, Params, TimeoutMS);
  try
    Result := ExtractResultObject(Response);
  finally
    Response.Free;
  end;
end;

class procedure TMCPElicitationService.ValidateSchemaProperty(const PropName: string;
  const PropSchema: TJSONObject);
begin
  var TypeValue := PropSchema.GetValue('type');
  if not Assigned(TypeValue) then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'requestedSchema.properties.' + PropName + ' must define a type.');

  var PropType := TypeValue.Value;
  if SameText(PropType, 'object') then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'requestedSchema.properties.' + PropName + ' cannot be a nested object.');

  if SameText(PropType, 'array') then
  begin
    var ItemsObj := PropSchema.GetValue('items') as TJSONObject;
    if not Assigned(ItemsObj) then
      raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
        'requestedSchema.properties.' + PropName + ' must define items for array values.');

    var ItemType := ItemsObj.GetValue('type');
    var HasEnum := Assigned(ItemsObj.GetValue('enum'));
    var HasAnyOf := Assigned(ItemsObj.GetValue('anyOf'));
    if (not Assigned(ItemType) or not SameText(ItemType.Value, 'string')) and not HasAnyOf then
      raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
        'requestedSchema.properties.' + PropName + ' array items must be string enums.');

    if not HasEnum and not HasAnyOf then
      raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
        'requestedSchema.properties.' + PropName + ' array items must define enum choices.');

    Exit;
  end;

  if not SameText(PropType, 'string') and
     not SameText(PropType, 'number') and
     not SameText(PropType, 'integer') and
     not SameText(PropType, 'boolean') then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'requestedSchema.properties.' + PropName + ' has unsupported type: ' + PropType);
end;

class procedure TMCPElicitationService.ValidateRequestedSchema(const RequestedSchema: TJSONObject);
begin
  if not Assigned(RequestedSchema) then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'Form elicitation requires a requestedSchema object.');

  var TypeValue := RequestedSchema.GetValue('type');
  if not Assigned(TypeValue) or not SameText(TypeValue.Value, 'object') then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'requestedSchema.type must be object.');

  var Properties := RequestedSchema.GetValue('properties') as TJSONObject;
  if not Assigned(Properties) then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'requestedSchema.properties must be an object.');

  for var Pair in Properties do
  begin
    if not (Pair.JsonValue is TJSONObject) then
      raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
        'requestedSchema.properties.' + Pair.JsonString.Value + ' must be an object.');

    ValidateSchemaProperty(Pair.JsonString.Value, Pair.JsonValue as TJSONObject);
  end;
end;

class function TMCPElicitationService.RequestForm(const Message: string;
  const RequestedSchema: TJSONObject; TimeoutMS: Cardinal): TJSONObject;
begin
  ValidateRequestedSchema(RequestedSchema);

  var Params := TJSONObject.Create;
  try
    Params.AddPair('mode', 'form');
    Params.AddPair('message', Message);
    Params.AddPair('requestedSchema', CloneJSONObject(RequestedSchema));
    Result := SendElicitationRequest(Params, TimeoutMS);
  finally
    Params.Free;
  end;
end;

class function TMCPElicitationService.RequestURL(const ElicitationID, URL,
  Message: string; TimeoutMS: Cardinal): TJSONObject;
begin
  if ElicitationID.Trim = '' then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'URL elicitation requires a non-empty elicitationId.');

  if URL.Trim = '' then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'URL elicitation requires a non-empty URL.');

  if Pos('://', URL) = 0 then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'URL elicitation requires an absolute URL.');

  var Params := TJSONObject.Create;
  try
    Params.AddPair('mode', 'url');
    Params.AddPair('elicitationId', ElicitationID);
    Params.AddPair('url', URL);
    Params.AddPair('message', Message);
    Result := SendElicitationRequest(Params, TimeoutMS);
  finally
    Params.Free;
  end;
end;

class procedure TMCPElicitationService.RaiseURLElicitationRequired(const ElicitationID,
  URL, Message: string);
begin
  if not IsURLElicitationCompleted(ElicitationID) then
  begin
    EnsureClientSupportsMode(CurrentSessionID, 'url');

    var ErrorData := TJSONObject.Create;
    try
      var Elicitations := TJSONArray.Create;
      ErrorData.AddPair('elicitations', Elicitations);

      var ElicitationObj := TJSONObject.Create;
      Elicitations.AddElement(ElicitationObj);
      ElicitationObj.AddPair('mode', 'url');
      ElicitationObj.AddPair('elicitationId', ElicitationID);
      ElicitationObj.AddPair('url', URL);
      ElicitationObj.AddPair('message', Message);

      raise EMCPJsonRpcError.Create(JSONRPC_URL_ELICITATION_REQUIRED,
        'This request requires more information.', ErrorData);
    finally
      ErrorData.Free;
    end;
  end;
end;

class procedure TMCPElicitationService.CompleteURLElicitation(const ElicitationID: string);
begin
  if ElicitationID.Trim = '' then
    raise EMCPJsonRpcError.Create(JSONRPC_INVALID_PARAMS,
      'A non-empty elicitationId is required.');

  var SessionID := CurrentSessionID;
  TMCPSessionManager.Instance.MarkElicitationCompleted(SessionID, ElicitationID);

  var Params := TJSONObject.Create;
  try
    Params.AddPair('elicitationId', ElicitationID);
    TMCPSessionManager.Instance.EnqueueNotification(SessionID,
      MCP_ELICITATION_NOTIFICATION_COMPLETE, Params);
  finally
    Params.Free;
  end;
end;

class function TMCPElicitationService.IsURLElicitationCompleted(
  const ElicitationID: string): Boolean;
begin
  Result := TMCPSessionManager.Instance.IsElicitationCompleted(
    CurrentSessionID, ElicitationID);
end;

end.