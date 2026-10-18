package io.github.junweiup.commonrelay;

import okhttp3.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;

/** Blocking file API: invoke on an application I/O executor. Staging contains ciphertext only. */
public final class RelayFiles {
    private final OkHttpClient http;
    private final String base,token;
    public RelayFiles(OkHttpClient http,String base,String token){if(!base.startsWith("https://"))throw new IllegalArgumentException("HTTPS required");this.http=http.newBuilder().followRedirects(false).followSslRedirects(false).build();this.base=base.replaceAll("/+$","");this.token=token;}
    public static JSONObject prepare(Crypto crypto,String to,File source,File staging,JSONObject metadata)throws Exception{
        if(!staging.createNewFile())throw new IOException("Staging already exists");staging.setReadable(false,false);staging.setWritable(false,false);staging.setReadable(true,true);staging.setWritable(true,true);
        String id=Crypto.hex(Crypto.random(16));MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(Crypto.SecretStream enc=new Crypto.SecretStream();InputStream input=new FileInputStream(source);DataOutputStream output=new DataOutputStream(new FileOutputStream(staging))){
            byte[] buffer=new byte[65519];long sequence=0;int count;
            do{count=input.read(buffer);byte[] plain=count<0?new byte[0]:Arrays.copyOf(buffer,count);byte[] cipher=enc.push(plain,crypto.aad(crypto.device,to,"file",id,sequence++),count<0);byte[] size=java.nio.ByteBuffer.allocate(4).putInt(cipher.length).array();output.write(size);output.write(cipher);digest.update(size);digest.update(cipher);}while(count>=0);
            output.flush();JSONObject wrapped=enc.descriptor().put("metadata",metadata);
            return new JSONObject().put("id",id).put("to",to).put("size",staging.length()).put("sha256",Crypto.hex(digest.digest())).put("metadata",crypto.seal(to,"file",id,wrapped));
        }
    }
    public static JSONObject decrypt(Crypto crypto,String from,JSONObject info,File staging,File destination)throws Exception{
        if(destination.exists())throw new IOException("Destination exists");String id=info.getString("id");JSONObject descriptor=crypto.open(from,"file",id,info.getString("metadata"));File temporary=File.createTempFile("relay-",".partial",destination.getParentFile());
        try(Crypto.SecretStream dec=new Crypto.SecretStream(descriptor);DataInputStream input=new DataInputStream(new FileInputStream(staging));OutputStream out=new FileOutputStream(temporary)){
            MessageDigest hash=MessageDigest.getInstance("SHA-256");long sequence=0;
            while(input.available()>0){int size=input.readInt();if(size<17||size>65536)throw new IOException("Invalid record size");byte[] cipher=new byte[size];input.readFully(cipher);hash.update(java.nio.ByteBuffer.allocate(4).putInt(size).array());hash.update(cipher);out.write(dec.pull(cipher,crypto.aad(from,crypto.device,"file",id,sequence++)));}
            if(!dec.finished||!Crypto.hex(hash.digest()).equals(info.getString("sha256")))throw new IOException("Truncated or corrupt file");out.flush();Files.move(temporary.toPath(),destination.toPath());return descriptor.getJSONObject("metadata");
        }finally{temporary.delete();}
    }
    private Response request(String method,String path,byte[] body,Map<String,String> headers)throws IOException{
        Request.Builder builder=new Request.Builder().url(base+path).header("Authorization","Bearer "+token);
        for(Map.Entry<String,String> h:headers.entrySet())builder.header(h.getKey(),h.getValue());
        RequestBody payload=body==null?null:RequestBody.create(body,MediaType.get("application/octet-stream"));
        if((method.equals("POST")||method.equals("PUT"))&&payload==null)payload=RequestBody.create(new byte[0],null);
        return http.newCall(builder.method(method,payload).build()).execute();
    }
    public JSONObject upload(JSONObject info,File staging)throws Exception{
        String id=info.getString("id");JSONObject status;
        try(Response r=request("POST","",info.toString().getBytes(StandardCharsets.UTF_8),Map.of())){
            if(r.code()==409){try(Response existing=request("GET","/"+id,null,Map.of())){if(!existing.isSuccessful())throw new IOException("Upload conflict");status=new JSONObject(existing.body().string());}}
            else{if(r.code()!=201)throw new IOException("File admission "+r.code());status=new JSONObject(r.body().string());}
        }
        for(String field:new String[]{"id","to","size","sha256","metadata"})if(!status.get(field).toString().equals(info.get(field).toString()))throw new IOException("Upload ID conflict");
        long offset=status.getLong("offset");try(RandomAccessFile input=new RandomAccessFile(staging,"r")){input.seek(offset);byte[] buffer=new byte[1<<20];int count;while((count=input.read(buffer))>0){try(Response r=request("PUT","/"+id+"/data",Arrays.copyOf(buffer,count),Map.of("Upload-Offset",Long.toString(offset)))){if(!r.isSuccessful())throw new IOException("Upload failed "+r.code());offset=new JSONObject(r.body().string()).getLong("offset");}}}
        try(Response r=request("POST","/"+id+"/commit",null,Map.of())){if(!r.isSuccessful())throw new IOException("Commit failed "+r.code());return new JSONObject(r.body().string());}
    }
    public JSONArray inbox()throws Exception{try(Response r=request("GET","",null,Map.of())){if(!r.isSuccessful())throw new IOException("Inbox failed");return new JSONArray(r.body().string());}}
    public void download(JSONObject info,File staging)throws Exception{
        long size=info.getLong("size");try(RandomAccessFile output=new RandomAccessFile(staging,"rw")){long offset=output.length();output.seek(offset);while(offset<size){long end=Math.min(size-1,offset+(1<<20)-1);try(Response r=request("GET","/"+info.getString("id")+"/data",null,Map.of("Range","bytes="+offset+"-"+end))){if(r.code()!=206)throw new IOException("Range refused");byte[] chunk=r.body().bytes();if(chunk.length!=end-offset+1)throw new IOException("Unexpected length");output.write(chunk);offset+=chunk.length;}}output.getFD().sync();}
    }
    public void acknowledge(String id)throws IOException{try(Response r=request("DELETE","/"+id,null,Map.of())){if(r.code()!=204)throw new IOException("Acknowledgement failed");}}
}
