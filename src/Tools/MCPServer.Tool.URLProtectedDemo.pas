unit MCPServer.Tool.URLProtectedDemo;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TURLProtectedDemoParams = class
  private
    FResourceName: string;
    FURL: string;
    FMessage: string;
    FElicitationID: string;
  public
    [Optional]
    [SchemaDescription('Name of the protected demo resource')]
    property ResourceName: string read FResourceName write FResourceName;

    [Optional]
    [SchemaDescription('Absolute URL to include in the URL-required error payload')]
    property URL: string read FURL write FURL;

    [Optional]
    [SchemaDescription('Message shown when authorization is required')]
    property Message: string read FMessage write FMessage;

    [Optional]
    [SchemaDescription('Stable elicitation ID used to unlock the resource after completion')]
    property ElicitationID: string read FElicitationID write FElicitationID;
  end;

  TURLProtectedDemoTool = class(TMCPToolBase<TURLProtectedDemoParams>)
  strict private
    class function NormalizeElicitationID(const Params: TURLProtectedDemoParams): string; static;
  protected
    function ExecuteWithParams(const Params: TURLProtectedDemoParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.Elicitation;

constructor TURLProtectedDemoTool.Create;
begin
  inherited;
  FName := 'url_protected_demo';
  FDescription := 'Returns -32042 until the matching URL elicitation is completed';
end;

class function TURLProtectedDemoTool.NormalizeElicitationID(
  const Params: TURLProtectedDemoParams): string;
begin
  Result := Params.ElicitationID;
  if Result <> '' then
    Exit;

  Result := Params.ResourceName;
  if Result = '' then
    Result := 'default-resource';

  Result := LowerCase(Result).Replace(' ', '-');
  Result := 'demo-protected-' + Result;
end;

function TURLProtectedDemoTool.ExecuteWithParams(
  const Params: TURLProtectedDemoParams): string;
begin
  var ResourceName := Params.ResourceName;
  if ResourceName = '' then
    ResourceName := 'demo-resource';

  var ElicitationID := NormalizeElicitationID(Params);
  if not TMCPElicitationService.IsURLElicitationCompleted(ElicitationID) then
  begin
    var URL := Params.URL;
    if URL = '' then
      URL := 'https://example.com/connect?elicitationId=' + ElicitationID;

    var Message := Params.Message;
    if Message = '' then
      Message := 'Authorization is required to access ' + ResourceName + '. Complete the URL flow and retry.';

    TMCPElicitationService.RaiseURLElicitationRequired(ElicitationID, URL, Message);
  end;

  Result := 'Protected demo resource granted: ' + ResourceName;
end;

initialization
  TMCPRegistry.RegisterTool('url_protected_demo',
    function: IMCPTool
    begin
      Result := TURLProtectedDemoTool.Create;
    end
  );

end.