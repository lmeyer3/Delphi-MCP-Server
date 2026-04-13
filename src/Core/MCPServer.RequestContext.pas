unit MCPServer.RequestContext;

interface

type
  TMCPRequestContext = class
  strict private
    class threadvar FSessionID: string;
  public
    class procedure Enter(const SessionID: string); static;
    class procedure Leave; static;
    class function CurrentSessionID: string; static;
  end;

implementation

class procedure TMCPRequestContext.Enter(const SessionID: string);
begin
  FSessionID := SessionID;
end;

class procedure TMCPRequestContext.Leave;
begin
  FSessionID := '';
end;

class function TMCPRequestContext.CurrentSessionID: string;
begin
  Result := FSessionID;
end;

end.