unit MCPServer.Tool.ElicitationDemo;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TElicitationDemoParams = class
  private
    FMode: string;
    FMessage: string;
    FDefaultName: string;
    FURL: string;
    FElicitationID: string;
  public
    [Optional]
    [SchemaDescription('Elicitation mode: form or url')]
    [SchemaEnum('form', 'url')]
    property Mode: string read FMode write FMode;

    [Optional]
    [SchemaDescription('Custom message shown to the user')]
    property Message: string read FMessage write FMessage;

    [Optional]
    [SchemaDescription('Default name pre-filled for form mode')]
    property DefaultName: string read FDefaultName write FDefaultName;

    [Optional]
    [SchemaDescription('Absolute URL to use for URL mode')]
    property URL: string read FURL write FURL;

    [Optional]
    [SchemaDescription('Optional fixed elicitation ID for URL mode')]
    property ElicitationID: string read FElicitationID write FElicitationID;
  end;

  TElicitationDemoTool = class(TMCPToolBase<TElicitationDemoParams>)
  strict private
    class function BuildRequestedSchema(const DefaultName: string): TJSONObject; static;
    class function ReadContentValue(const Response: TJSONObject; const Name: string): string; static;
  protected
    function ExecuteWithParams(const Params: TElicitationDemoParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.Elicitation;

constructor TElicitationDemoTool.Create;
begin
  inherited;
  FName := 'elicitation_demo';
  FDescription := 'Exercise form or URL elicitation over the active HTTP session';
end;

class function TElicitationDemoTool.BuildRequestedSchema(const DefaultName: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');

  var Properties := TJSONObject.Create;
  Result.AddPair('properties', Properties);

  var NameProperty := TJSONObject.Create;
  Properties.AddPair('name', NameProperty);
  NameProperty.AddPair('type', 'string');
  NameProperty.AddPair('title', 'Display name');
  NameProperty.AddPair('description', 'Name to use for this elicitation demo');
  if DefaultName <> '' then
    NameProperty.AddPair('default', DefaultName);

  var EmailProperty := TJSONObject.Create;
  Properties.AddPair('email', EmailProperty);
  EmailProperty.AddPair('type', 'string');
  EmailProperty.AddPair('title', 'Email address');
  EmailProperty.AddPair('description', 'Optional contact email');
  EmailProperty.AddPair('format', 'email');

  var SubscribeProperty := TJSONObject.Create;
  Properties.AddPair('subscribe', SubscribeProperty);
  SubscribeProperty.AddPair('type', 'boolean');
  SubscribeProperty.AddPair('title', 'Subscribe');
  SubscribeProperty.AddPair('description', 'Opt in to demo notifications');
  SubscribeProperty.AddPair('default', TJSONBool.Create(False));

  var RequiredArray := TJSONArray.Create;
  RequiredArray.Add('name');
  Result.AddPair('required', RequiredArray);
end;

class function TElicitationDemoTool.ReadContentValue(const Response: TJSONObject;
  const Name: string): string;
begin
  Result := '';
  var Content := Response.GetValue('content') as TJSONObject;
  if not Assigned(Content) then
    Exit;

  var Value := Content.GetValue(Name);
  if Assigned(Value) then
    Result := Value.Value;
end;

function TElicitationDemoTool.ExecuteWithParams(const Params: TElicitationDemoParams): string;
begin
  var Mode := Params.Mode;
  if Mode = '' then
    Mode := 'form';

  if SameText(Mode, 'url') then
  begin
    var ElicitationID := Params.ElicitationID;
    if ElicitationID = '' then
      ElicitationID := 'demo-url-' + TGuid.NewGuid.ToString;

    var URL := Params.URL;
    if URL = '' then
      URL := 'https://example.com/connect?elicitationId=' + ElicitationID;

    var Message := Params.Message;
    if Message = '' then
      Message := 'Open the URL to continue the MCP URL elicitation demo.';

    var Response := TMCPElicitationService.RequestURL(ElicitationID, URL, Message);
    try
      Result := 'URL elicitation action: ' + Response.GetValue('action').Value + ' (' + ElicitationID + ')';
    finally
      Response.Free;
    end;
    Exit;
  end;

  var RequestedSchema := BuildRequestedSchema(Params.DefaultName);
  try
    var Message := Params.Message;
    if Message = '' then
      Message := 'Please provide your demo profile information.';

    var Response := TMCPElicitationService.RequestForm(Message, RequestedSchema);
    try
      var Action := Response.GetValue('action').Value;
      if not SameText(Action, 'accept') then
      begin
        Result := 'Form elicitation action: ' + Action;
        Exit;
      end;

      Result := Format('Form accepted: name=%s, email=%s, subscribe=%s', [
        ReadContentValue(Response, 'name'),
        ReadContentValue(Response, 'email'),
        ReadContentValue(Response, 'subscribe')
      ]);
    finally
      Response.Free;
    end;
  finally
    RequestedSchema.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('elicitation_demo',
    function: IMCPTool
    begin
      Result := TElicitationDemoTool.Create;
    end
  );

end.