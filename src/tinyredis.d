module tinyredis;

private:
    import std.array     : split, join;
    import std.algorithm : find, findSplitAfter;
    import std.stdio     : writeln;
    import  std.socket,
    		std.conv
    	;

public :
    enum ResponseType : byte 
    {
        Status,
        Error,
        Integer,
        Bulk,
        MultiBulk,
        Nil
    };
        
    class Redis
    {
        private :
            Socket conn;
        
        public :
            this(string host = "localhost", ushort port = 6379)
            {
                conn = new TcpSocket(new InternetAddress(host, port));
            }
            
            Response send(string request)
                in { assert(request.length > 2); }
                body 
                {
                    auto mb = toMultiBulk(request);
                    debug { writeln("Request : ", "'"~request~"' (MultiBulk : '", escape(mb) ~ "')"); }
                    
                    auto sent = conn.send(mb);
                    if (sent == 0)
                        throw new ConnectionException("Error while sending request");
                        
                    byte[1024] buff;
                    byte[] rez;
                    long len;
                    do{
                        len = conn.receive(buff);
                        rez ~= buff[0 .. len];
                    }while(len > buff.length);
                    
                    debug { writeln("Response : ", "'" ~ escape(cast(string)rez) ~ "'"); }
                    
                    return parse(rez);
                }
    }

private :

    const string CRLF = "\r\n";

    struct Response
    {
        ResponseType type;
        
        union{
            string value;
            int intval;
            string[] values;
        }
        
        @property string toString()
        {
            switch(type)
            {
                case ResponseType.Nil : 
                    return "(Nil)";
                
                case ResponseType.Integer : 
                    return "(Integer) "  ~ to!(string)(intval);
                    
                case ResponseType.Status :
                case ResponseType.Bulk : 
                    return value;
                    
                case ResponseType.MultiBulk :
                    return "[\"" ~ join(values, "\", \"") ~ "\"]";
                    
                default:
                    return "";
            }
        }
    }

    Response parse(const(byte[]) response)
        in{ assert(response.length > 0); }
        body
        {
            switch(response[0])
            {
                case '+' : 
                    Response r = Response(ResponseType.Status, cast(string)response[1 .. $-2]);
                    return r;
                    
                case '-' :
                    throw new RedisResponseException(cast(string)response[1 .. $-2]);

                case ':' :
                    Response r = {ResponseType.Integer};
                    r.intval = to!int(cast(char[])response[1 .. $ - 2]);
                    return r;
                
                case '$' :
                    Response r;
                    
                    if(response == "$-1"~CRLF)
                        r = Response(ResponseType.Nil);
                    else
                        r = Response(ResponseType.Bulk, cast(string)std.algorithm.find(response, CRLF)[2 .. $-2]);
                        
                    return r;

                case '*' :
                    Response r = {ResponseType.MultiBulk};
                    r.values = parseMultiBulk(response);
                    return r;
                    
                default : 
                    throw new Exception("Cannot understand response!");
            }

        }
    
    string[] parseMultiBulk(const(byte[]) mb)
    {
        auto l = findSplitAfter(mb, CRLF);
        uint length = to!uint(cast(char[])l[0][1 .. $-2]);
        
        auto bulks = mb[l[0].length .. $];
        
        string[] rez;
        for(uint i = 0; i < length; i++)
        {
            bulks = bulks[1 .. $];
            ulong pos = 0;
            char[] lgth;
            
            foreach(p, byte c; bulks)
            {
                if(c == 13) //'\r' 
                    break;
                    
                lgth ~= c;
                pos = p;
            }
            pos += lgth.length + 2;
            
            int bytes = to!int(lgth);
            
            if(bytes > -1)
            {
                rez ~= cast(string)bulks[pos .. pos + bytes];
                pos += bytes;
            }
            
            pos += 2;
            bulks = bulks[pos .. $];
        }
        
        return rez;
    }
    
    string toMultiBulk(string str)
    {
        auto cmds = std.array.split(str);
        
        char[] res = "*" ~ to!(char[])(cmds.length) ~ CRLF;
        foreach(cmd; cmds)
            res ~= toBulk(cmd);
        
        return cast(string)res;
    }
    
    string toBulk(string str)
    {
        auto bytes = cast(byte[])str;
        return "$" ~ to!string(bytes.length) ~ CRLF ~ str ~ CRLF;
    }
    
    string escape(string str)
    {
         return std.array.replace(str,"\r\n","\\r\\n");
    }
    
    /* -------- EXCEPTIONS ------------- */
    
    class ParseException : Exception {
        this(string msg) { super(msg); }
    }
    
    class RedisResponseException : Exception {
        this(string msg) { super(msg); }
    }
    
    class ConnectionException : Exception {
        this(string msg) { super(msg); }
    }

unittest
{
    assert(toBulk("$2") == "$2\r\n$2\r\n");
    assert(toMultiBulk("GET *") == "*2\r\n$3\r\nGET\r\n$1\r\n*\r\n");
 
    auto redis = new Redis();
    auto response = redis.send("LASTSAVE");
    assert(response.type == ResponseType.Integer);
    
    writeln(redis.send("SET name adil"));
    response = redis.send("GET name");
    assert(response.type == ResponseType.Bulk);
    assert(response.value == "adil");
    
    response = redis.send("GET nonexistentkey");
    assert(response.type == ResponseType.Nil);
    
    writeln(redis.send("DEL myset"));
    writeln(redis.send("SADD myset adil"));
    writeln(redis.send("SADD myset 350001939"));
    writeln(redis.send("SADD myset $3"));
    
    Response r = redis.send("SMEMBERS myset");
    assert(r.type == ResponseType.MultiBulk);
    assert(r.values.length == 3);
}