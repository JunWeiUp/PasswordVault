# JNA resolves native methods, Structure fields and callbacks by reflection/name.
# Keep the small FFI boundary intact while R8 removes unused UI/dependency code.
-keep class com.sun.jna.** { *; }
-keep class com.securepass.vault.core.** { *; }
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,InnerClasses,EnclosingMethod,Signature
# JNA includes optional desktop helpers that are never used by the Android client.
-dontwarn java.awt.**
