module tinyredis;

private:
    import std.array     : split, join;
    import std.algorithm : find, findSplitAfter;
    import std.stdio     : writeln;
    import std.conv      : to, text;
    import std.socket;

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
            
            ~this()
            {
                if(conn.isAlive())
                    conn.close();
            }
            
            /**
             * Send a request using any type that can be converted to a string
             *
             * send("SADD", "myset", 1)
             * send("SADD", "myset", 1.2)
             * send("SADD", "myset", true)
             * send("SADD", "myset", "Batman")
             * send("SADD", "myset", object) //provided toString is implemented
             * send("GET", "*") == send("GET *")
             */
            Response send(T...)(string key, T args)
            {
                static if(args.length == 0)
                    return blockingRequest(conn, key);
                else
                {    
                    string query = key;
                    foreach(a; args)
                        query ~= " " ~ text(a);
                            
                    return blockingRequest(conn, query);
                }
            }
            
            /**
             * Send a request with a parameterized array. Ex:
             * send("SREM", ["myset", "$3", "$4"]) == send("SREM myset $3 $4")
             *
             */
            Response send(T)(string key, T[] args)
            {
                string query = key;
                
                static if(is(T == string))
                    query ~= " " ~ args.join(" ");
                else
                    foreach(a; args)
                        query ~= " " ~ text(a);
                        
                return blockingRequest(conn, query);
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
            Response[] values;
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
                    return text(values);
                    
                default:
                    return "";
            }
        }
    }
    
    Response blockingRequest(Socket conn, string request)
    in { assert(request.length > 0); }
    body {
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
    
    
    /* ---------- RESPONSE PARSING FUNCTIONS ----------- */

    /**
     * Parse a response from Redis
     */
    Response parse(const(byte[]) response)
    in { assert(response.length > 0); }
//    out{ assert(response.length == pos); } //Can i do this?
    body
    {
        ulong pos; //Not used here
        return parseResponse(response, pos);
    }
    
    /**
     * Parse a byte stream into a response
     */
    Response parseResponse(const(byte[]) mb, ref ulong pos)
    {
        char type = mb[0];
        Response response;
        auto bytes = getData(mb[1 .. $]); //This could be an int value (:), a bulk byte length ($), a status message (+) or an error value (-)
        pos = 1 + bytes.length + 2;
        
        switch(type)
        {
             case '+' : 
                response = Response(ResponseType.Status, cast(string)bytes);
                return response;
                
            case '-' :
                throw new RedisResponseException(cast(string)bytes);
                
            case ':' :
                response.type = ResponseType.Integer;
                response.intval = to!int(cast(char[])bytes);
                return response;
            
            case '$' :
                int l = to!int(cast(char[])bytes);
                if(l == -1)
                {
                    response.type = ResponseType.Nil;
                    pos = 5;
                    return response;
                }
                
                response.type = ResponseType.Bulk;
                if(l > 0)
                    response.value = cast(string)mb[pos .. pos + l];
                
                pos += l + 2;
                return response;
            
            case '*' :
                response.type = ResponseType.MultiBulk;
                int items = to!int(cast(char[])bytes);
                
                ulong cp = 0;
                auto data = mb[pos .. $];
                for(uint i = 0; i < items; i++)
                {
                    response.values ~= parseResponse(data, cp);
                    data = data[cp .. $];
                    pos += cp;
                }
                
                return response;
            
            default :
                throw new Exception("Cannot understand response!");
        }
    }
    
    byte[] getData(const(byte[]) mb)
    {
        byte[] lgth;
        foreach(p, byte c; mb)
        {
            if(c == 13) //'\r' 
                break;
                
            lgth ~= c;
        }
        return lgth;
    }
    
    
    /* --------- BULK HANDLING FUNCTIONS ---------- */
    
    string toMultiBulk(string command)
    {
        string[] cmds = command.split();
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
    
    Response response = parse(cast(byte[])"*4\r\n$3\r\nGET\r\n$1\r\n*\r\n:123\r\n+A Status Message\r\n");
    assert(response.type == ResponseType.MultiBulk);
    assert(response.values.length == 4);
    assert(response.values[0].value == "GET");
    assert(response.values[1].value == "*");
    assert(response.values[2].intval == 123);
    assert(response.values[3].value == "A Status Message");
    //writeln(response);
 
    auto redis = new Redis();
    response = redis.send("LASTSAVE");
    assert(response.type == ResponseType.Integer);
    
    redis.send("SET", "name", "adil");
    response = redis.send("GET name");
    assert(response.type == ResponseType.Bulk);
    assert(response.value == "adil");
    
    response = redis.send("GET nonexistentkey");
    assert(response.type == ResponseType.Nil);
    
    redis.send("DEL myset");
    redis.send("SADD myset adil");
    redis.send("SADD myset 350001939");
    redis.send("SADD myset $3");
    redis.send("SADD",["myset","$4"]);
    
    Response r = redis.send("SMEMBERS myset");
    assert(r.type == ResponseType.MultiBulk);
    assert(r.values.length == 4);
}