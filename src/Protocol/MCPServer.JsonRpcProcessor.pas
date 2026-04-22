unit MCPServer.JsonRpcProcessor;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Logger;

type
  TMCPJsonRpcProcessor = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    class function ParseJSONRequest(const RequestBody: string): TJSONObject;
    class function ExtractRequestID(JSONRequest: TJSONObject): TValue;
    class function CreateJSONResponse(const RequestID: TValue): TJSONObject;
    class procedure AddRequestIDToResponse(Response: TJSONObject; const RequestID: TValue);
    class function ExecuteMethodCall(ManagerRegistry: IMCPManagerRegistry; const MethodName: string;
      Params: TJSONObject; const SessionID: string): TValue;
    class function CreateErrorResponse(const RequestID: TValue; ErrorCode: Integer;
      const ErrorMessage: string; const ErrorData: TJSONObject = nil): string;
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry);
    function ProcessRequest(const RequestBody: string; const SessionID: string): string;
  end;

implementation

uses
  MCPServer.RequestContext;

{ TMCPJsonRpcProcessor }

constructor TMCPJsonRpcProcessor.Create(ManagerRegistry: IMCPManagerRegistry);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
end;

class function TMCPJsonRpcProcessor.ParseJSONRequest(const RequestBody: string): TJSONObject;
begin
  var ParsedValue := TJSONObject.ParseJSONValue(RequestBody);
  if not Assigned(ParsedValue) then
    raise Exception.Create('Invalid JSON');

  if not (ParsedValue is TJSONObject) then
  begin
    ParsedValue.Free;
    raise Exception.Create('JSON-RPC request must be an object');
  end;

  Result := ParsedValue as TJSONObject;
end;

class function TMCPJsonRpcProcessor.ExtractRequestID(JSONRequest: TJSONObject): TValue;
begin
  if not Assigned(JSONRequest) then
  begin
    Result := TValue.Empty;
    Exit;
  end;

  var IdValue := JSONRequest.GetValue('id');
  if not Assigned(IdValue) then
  begin
    Result := TValue.Empty;
    Exit;
  end;

  if IdValue is TJSONNumber then
    Result := TValue.From<Int64>((IdValue as TJSONNumber).AsInt64)
  else if IdValue is TJSONString then
    Result := TValue.From<string>((IdValue as TJSONString).Value)
  else
    Result := TValue.Empty;
end;

class function TMCPJsonRpcProcessor.CreateJSONResponse(const RequestID: TValue): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  AddRequestIDToResponse(Result, RequestID);
end;

class procedure TMCPJsonRpcProcessor.AddRequestIDToResponse(Response: TJSONObject;
  const RequestID: TValue);
begin
  if RequestID.IsEmpty then
  begin
    Response.AddPair('id', TJSONNull.Create);
    Exit;
  end;

  if RequestID.Kind in [tkString, tkUString, tkWString, tkLString] then
    Response.AddPair('id', RequestID.AsString)
  else if RequestID.Kind in [tkInteger, tkInt64] then
    Response.AddPair('id', TJSONNumber.Create(RequestID.AsInt64))
  else
    Response.AddPair('id', TJSONNull.Create);
end;

class function TMCPJsonRpcProcessor.ExecuteMethodCall(
  ManagerRegistry: IMCPManagerRegistry; const MethodName: string; Params: TJSONObject;
  const SessionID: string): TValue;
begin
  if not Assigned(ManagerRegistry) then
    raise Exception.Create('Manager registry not initialized');

  var Manager := ManagerRegistry.GetManagerForMethod(MethodName);
  if not Assigned(Manager) then
    raise Exception.CreateFmt('Method [%s] not found. The method does not exist or is not available.', [MethodName]);

  TMCPRequestContext.Enter(SessionID);
  try
    Result := Manager.ExecuteMethod(MethodName, Params);
  finally
    TMCPRequestContext.Leave;
  end;
end;

class function TMCPJsonRpcProcessor.CreateErrorResponse(const RequestID: TValue;
  ErrorCode: Integer; const ErrorMessage: string; const ErrorData: TJSONObject): string;
begin
  var JSONResponse := CreateJSONResponse(RequestID);
  try
    var ErrorObj := TJSONObject.Create;
    JSONResponse.AddPair('error', ErrorObj);
    ErrorObj.AddPair('code', TJSONNumber.Create(ErrorCode));
    ErrorObj.AddPair('message', ErrorMessage);
    if Assigned(ErrorData) then
      ErrorObj.AddPair('data', TJSONObject.ParseJSONValue(ErrorData.ToJSON) as TJSONObject);
    Result := JSONResponse.ToJSON;
  finally
    JSONResponse.Free;
  end;
end;

function TMCPJsonRpcProcessor.ProcessRequest(const RequestBody: string; const SessionID: string): string;
begin
  Result := '';
  var JSONRequest: TJSONObject := nil;
  var JSONResponse: TJSONObject := nil;
  var ErrorData: TJSONObject := nil;

  try
    try
      JSONRequest := ParseJSONRequest(RequestBody);

      var RequestID := ExtractRequestID(JSONRequest);
      var MethodValue := JSONRequest.GetValue('method');
      var ResultValue := JSONRequest.GetValue('result');
      var ErrorValue := JSONRequest.GetValue('error');

      if Assigned(ResultValue) or Assigned(ErrorValue) then
        Exit;

      if not Assigned(MethodValue) or (MethodValue.Value = '') then
        raise Exception.Create('JSON-RPC request must include a method');

      var MethodName := MethodValue.Value;
      var ParamsValue := JSONRequest.GetValue('params');
      var Params: TJSONObject := nil;
      if Assigned(ParamsValue) and (ParamsValue is TJSONObject) then
        Params := ParamsValue as TJSONObject;

      if RequestID.IsEmpty then
      begin
        ExecuteMethodCall(FManagerRegistry, MethodName, Params, SessionID);
        Exit;
      end;

      JSONResponse := CreateJSONResponse(RequestID);

      var ExecuteResult := ExecuteMethodCall(FManagerRegistry, MethodName, Params, SessionID);
      if not ExecuteResult.IsEmpty then
      begin
        if ExecuteResult.IsType<TJSONObject> then
          JSONResponse.AddPair('result', ExecuteResult.AsType<TJSONObject>)
        else if ExecuteResult.IsType<string> then
          JSONResponse.AddPair('result', ExecuteResult.AsString)
        else
          JSONResponse.AddPair('result', ExecuteResult.ToString);
      end;

      Result := JSONResponse.ToJSON;

    except
      on E: Exception do
      begin
        TLogger.Error('Error processing request: ' + E.Message);

        var ErrorCode := JSONRPC_INTERNAL_ERROR;
        if E is EMCPJsonRpcError then
        begin
          ErrorCode := EMCPJsonRpcError(E).Code;
          ErrorData := EMCPJsonRpcError(E).Data;
        end
        else if Pos('not found', E.Message) > 0 then
          ErrorCode := JSONRPC_METHOD_NOT_FOUND;

        Result := CreateErrorResponse(ExtractRequestID(JSONRequest), ErrorCode, E.Message, ErrorData);
      end;
    end;
  finally
    JSONRequest.Free;
    JSONResponse.Free;
  end;
end;

end.