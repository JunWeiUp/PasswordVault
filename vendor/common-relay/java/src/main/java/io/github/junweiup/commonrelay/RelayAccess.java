package io.github.junweiup.commonrelay;

/** Server-wide access password sent as {@value #HEADER} on every /relay/v1 request. It is not an end-to-end key. */
public final class RelayAccess {
    public static final String HEADER="Relay-Access";
    private RelayAccess(){}
    /** Returns the password unchanged when null or 8-128 printable ASCII characters (0x21-0x7E); otherwise throws without echoing it. */
    public static String validate(String password){
        if(password==null)return null;
        if(password.length()<8||password.length()>128)throw new IllegalArgumentException("Relay access password must be 8-128 printable ASCII characters");
        for(int i=0;i<password.length();i++){char c=password.charAt(i);if(c<0x21||c>0x7e)throw new IllegalArgumentException("Relay access password must be 8-128 printable ASCII characters");}
        return password;
    }
}
