unit MCPServer.Tool.CompleteURLDemo;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TCompleteURLDemoParams = class
  private
    FElicitationID: string;
  public
    [SchemaDescription('The elicitation ID to mark as complete for the active session')]
    property ElicitationID: string read FElicitationID write FElicitationID;
  end;

  TCompleteURLDemoTool = class(TMCPToolBase<TCompleteURLDemoParams>)
  protected
    function ExecuteWithParams(const Params: TCompleteURLDemoParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.Elicitation;

constructor TCompleteURLDemoTool.Create;
begin
  inherited;
  FName := 'complete_url_demo';
  FDescription := 'Marks a URL elicitation as complete and queues the completion notification';
end;

function TCompleteURLDemoTool.ExecuteWithParams(
  const Params: TCompleteURLDemoParams): string;
begin
  TMCPElicitationService.CompleteURLElicitation(Params.ElicitationID);
  Result := 'Completed URL elicitation: ' + Params.ElicitationID;
end;

initialization
  TMCPRegistry.RegisterTool('complete_url_demo',
    function: IMCPTool
    begin
      Result := TCompleteURLDemoTool.Create;
    end
  );

end.