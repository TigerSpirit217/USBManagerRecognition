package com.tiger.usbmanager.auth;

import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.security.spec.*;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.*;

/** Root app_process entry point that owns the USB Authenticate FunctionFS endpoints. */
public final class UsbAuthDaemon {
    public static final String INTERFACE_GUID = "{8F60D3B2-3D44-4D15-8F28-5A46D65E0F31}";
    private static native void nativeOpen(String mount, byte[] descriptors, byte[] strings) throws IOException;
    private static native byte[] nativeReceive() throws IOException;
    private static native void nativeSend(byte[] bytes) throws IOException;
    private static native long nativeGeneration();

    private static byte[] descriptors() {
        ByteBuffer b = ByteBuffer.allocate(512).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(3).putInt(0).putInt(15);
        b.putInt(3).putInt(3).putInt(5).putInt(2);
        for (int speed = 0; speed < 3; speed++) {
            b.put(new byte[]{9,4,0,0,2,(byte)255,0,0,1});
            for (int endpoint : new int[]{1,130}) {
                b.put((byte)7).put((byte)5).put((byte)endpoint).put((byte)2);
                b.putShort((short)(speed == 0 ? 64 : speed == 1 ? 512 : 1024)).put((byte)0);
                if (speed == 2) b.put(new byte[]{6,48,0,0,0,0});
            }
        }
        b.put((byte)0).putInt(35).putShort((short)1).putShort((short)4).putShort((short)1);
        b.put((byte)0).put((byte)1).put(new byte[]{'W','I','N','U','S','B',0,0}).put(new byte[14]);
        byte[] name = "DeviceInterfaceGUID\0".getBytes(StandardCharsets.US_ASCII);
        byte[] value = (INTERFACE_GUID + "\0").getBytes(StandardCharsets.US_ASCII);
        int size = 14 + name.length + value.length;
        b.put((byte)0).putInt(11 + size).putShort((short)1).putShort((short)5).putShort((short)1);
        b.putInt(size).putInt(1).putShort((short)name.length).put(name).putInt(value.length).put(value);
        b.putInt(4, b.position());
        return Arrays.copyOf(b.array(), b.position());
    }

    private static byte[] strings() {
        byte[] name = "USB Authenticate\0".getBytes(StandardCharsets.UTF_8);
        return ByteBuffer.allocate(18 + name.length).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(2).putInt(18 + name.length).putInt(1).putInt(1)
                .putShort((short)0x409).put(name).array();
    }

    private static String b64(byte[] value) { return Base64.getEncoder().encodeToString(value); }
    private static byte[] unb64(String value) { return Base64.getDecoder().decode(value); }
    private static String hex(byte[] value) {
        StringBuilder result = new StringBuilder(value.length * 2);
        for (byte b : value) result.append(String.format(Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }

    private static byte[] hkdf(byte[] secret, byte[] salt, byte[] info, int length) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(secret);
        byte[] result = new byte[length], previous = new byte[0];
        int offset = 0, counter = 1;
        while (offset < length) {
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            mac.update(previous); mac.update(info); mac.update((byte)counter++);
            previous = mac.doFinal();
            int copy = Math.min(previous.length, length - offset);
            System.arraycopy(previous, 0, result, offset, copy); offset += copy;
        }
        Arrays.fill(prk, (byte)0);
        return result;
    }

    private static byte[] decrypt(byte[] key, byte[] iv, byte[] encrypted, byte[] aad) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        cipher.updateAAD(aad);
        return cipher.doFinal(encrypted);
    }

    private static byte[] encrypt(byte[] key, byte[] iv, byte[] clear, byte[] aad) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        cipher.updateAAD(aad);
        return cipher.doFinal(clear);
    }

    private static Properties readHost(Path file) throws IOException {
        Properties p = new Properties();
        try (InputStream input = Files.newInputStream(file)) { p.load(input); }
        return p;
    }

    private static void setProfile(Properties p, String spec) {
        String[] fields = spec.split(",", -1);
        if (fields.length != 3 || !Arrays.asList("none", "mtp", "ptp", "rndis", "midi").contains(fields[1])
                || !(fields[2].equals("true") || fields[2].equals("false"))) throw new IllegalArgumentException("profile");
        String name = new String(unb64(fields[0]), StandardCharsets.UTF_8).trim();
        if (name.length() > 64 || name.chars().anyMatch(Character::isISOControl))
            throw new IllegalArgumentException("name");
        if (!name.isEmpty()) p.setProperty("label", name);
        else if (p.getProperty("label", "").isEmpty()) throw new IllegalArgumentException("name");
        p.setProperty("mode", fields[1]); p.setProperty("adb", fields[2]);
    }

    private static void saveHost(Path file, Properties p) throws IOException {
        Path temp = file.resolveSibling(file.getFileName() + ".tmp");
        try (FileOutputStream output = new FileOutputStream(temp.toFile())) {
            p.store(output, "USBManager authenticated computer"); output.getFD().sync();
        }
        Files.move(temp, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }

    private static String profileFields(Properties p) {
        return "|" + p.getProperty("mode", "") + "|" + p.getProperty("adb", "false");
    }

    private static final class Session {
        private final Path hosts;
        private final Path result;
        private boolean allowPair;
        private final String pairingProfile;
        private Properties authenticated = new Properties();
        private String hostPublic, hostEphemeral, pcNonce, label;
        private byte[] transcript, sessionKey;
        private long issued;

        Session(Path hosts, Path result, boolean allowPair, String pairingProfile) throws IOException {
            this.pairingProfile = pairingProfile;
            this.hosts = hosts; this.result = result; this.allowPair = allowPair; Files.createDirectories(hosts);
        }

        void reset() { sessionKey = null; transcript = null; }

        private void writeResult(String status, String id, String displayLabel) throws IOException {
            String line = status + "|" + id + "|" + b64(displayLabel.getBytes(StandardCharsets.UTF_8)) + profileFields(authenticated) + "\n";
            Path temp = result.resolveSibling(result.getFileName() + ".tmp");
            Files.write(temp, line.getBytes(StandardCharsets.US_ASCII), StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
            Files.move(temp, result, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        }

        String handle(String request) {
            try {
                String[] fields = request.split(" ", -1);
                if (fields.length == 5 && fields[0].equals("HELLO2")) {
                    hostPublic = fields[1]; hostEphemeral = fields[2]; pcNonce = fields[3];
                    label = new String(unb64(fields[4]), StandardCharsets.UTF_8);
                    if (!label.matches("[\\p{L}\\p{N} _.-]{1,64}")) return "ERROR2 LABEL";
                    PublicKey peer = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(unb64(hostEphemeral)));
                    KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
                    generator.initialize(new ECGenParameterSpec("secp256r1"));
                    KeyPair ephemeral = generator.generateKeyPair();
                    byte[] phoneNonceBytes = new byte[32]; new SecureRandom().nextBytes(phoneNonceBytes);
                    String phoneEphemeral = b64(ephemeral.getPublic().getEncoded());
                    String phoneNonce = b64(phoneNonceBytes);
                    String text = "USBMANAGER/2\n" + hostPublic + "\n" + hostEphemeral + "\n" + phoneEphemeral + "\n" + pcNonce + "\n" + phoneNonce + "\n" + fields[4];
                    transcript = text.getBytes(StandardCharsets.US_ASCII);
                    KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
                    agreement.init(ephemeral.getPrivate()); agreement.doPhase(peer, true);
                    byte[] salt = MessageDigest.getInstance("SHA-256").digest((pcNonce + phoneNonce).getBytes(StandardCharsets.US_ASCII));
                    sessionKey = hkdf(agreement.generateSecret(), salt, "USBManager Auth v2".getBytes(StandardCharsets.US_ASCII), 32);
                    issued = System.nanoTime();
                    return "CHALLENGE2 " + phoneEphemeral + " " + phoneNonce;
                }
                if (fields.length == 4 && fields[0].equals("AUTH2")) {
                    byte[] key = sessionKey; byte[] aad = transcript;
                    sessionKey = null; transcript = null;
                    if (key == null || aad == null || System.nanoTime() - issued > 30_000_000_000L) return "ERROR2 CHALLENGE";
                    String action = new String(decrypt(key, unb64(fields[2]), unb64(fields[3]), aad), StandardCharsets.US_ASCII);
                    if (!action.equals("LOOKUP") && !action.equals("PAIR")) return "ERROR2 ACTION";
                    PublicKey identity = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(unb64(hostPublic)));
                    Signature verifier = Signature.getInstance("SHA256withECDSA"); verifier.initVerify(identity);
                    verifier.update(aad); verifier.update((byte)'\n'); verifier.update(action.getBytes(StandardCharsets.US_ASCII));
                    if (!verifier.verify(unb64(fields[1]))) return "ERROR2 SIGNATURE";
                    String id = hex(MessageDigest.getInstance("SHA-256").digest(identity.getEncoded()));
                    Path file = hosts.resolve(id + ".properties");
                    String status;
                    if (Files.exists(file)) {
                        authenticated = readHost(file);
                        label = authenticated.getProperty("label", label);
                        authenticated.setProperty("lastSeen", Long.toString(System.currentTimeMillis()));
                        saveHost(file, authenticated);
                        status = "KNOWN " + id + " " + b64(label.getBytes(StandardCharsets.UTF_8));
                    }
                    else if (!action.equals("PAIR")) status = "UNKNOWN " + id;
                    else if (!allowPair) status = "ERROR PAIRING_CLOSED";
                    else {
                        Properties properties = new Properties();
                        properties.setProperty("label", label);
                        setProfile(properties, pairingProfile);
                        properties.setProperty("id", id);
                        properties.setProperty("publicKey", hostPublic);
                        properties.setProperty("lastSeen", Long.toString(System.currentTimeMillis()));
                        saveHost(file, properties);
                        authenticated = properties;
                        label = properties.getProperty("label");
                        allowPair = false;
                        status = "PAIRED " + id + " " + b64(label.getBytes(StandardCharsets.UTF_8));
                    }
                    if (status.startsWith("KNOWN ")) writeResult("KNOWN", id, label);
                    else if (status.startsWith("PAIRED ")) writeResult("PAIRED", id, label);
                    else if (status.startsWith("UNKNOWN ")) writeResult("UNKNOWN", id, label);
                    byte[] iv = new byte[12]; new SecureRandom().nextBytes(iv);
                    return "RESULT2 " + b64(iv) + " " + b64(encrypt(key, iv, status.getBytes(StandardCharsets.UTF_8), aad));
                }
                return "ERROR2 FORMAT";
            } catch (Exception error) {
                return "ERROR2 INVALID";
            }
        }
    }

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Exception | LinkageError error) {
            System.err.println("AUTH_DAEMON_ERROR " + error.getClass().getSimpleName() + ": " + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void run(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("self-test")) {
            System.load(args[1]);
            nativeGeneration();
            System.out.println("NATIVE_READY");
            return;
        }
        if (args.length >= 2 && args[0].equals("list")) {
            try (DirectoryStream<Path> files = Files.newDirectoryStream(Paths.get(args[1]), "*.properties")) {
                for (Path file : files) {
                    Properties p = readHost(file);
                    System.out.println(p.getProperty("id") + "|" + b64(p.getProperty("label", "Computer").getBytes(StandardCharsets.UTF_8))
                            + "|" + p.getProperty("lastSeen", "0") + profileFields(p));
                }
            }
            return;
        }
        if (args.length == 4 && args[0].equals("edit")) {
            if (!args[2].matches("[0-9a-f]{64}")) throw new IllegalArgumentException("id");
            Path file = Paths.get(args[1]).resolve(args[2] + ".properties");
            Properties p = readHost(file); setProfile(p, args[3]); saveHost(file, p);
            System.out.println("UPDATED"); return;
        }
        if (args.length != 6) throw new IllegalArgumentException("<native-lib> <ffs-mount> <host-dir> <pair|closed> <result-file> <profile>");
        System.load(args[0]);
        Session session = new Session(Paths.get(args[2]), Paths.get(args[4]), args[3].equals("pair"), args[5]);
        nativeOpen(args[1], descriptors(), strings());
        System.out.println("READY " + INTERFACE_GUID); System.out.flush();
        long generation = nativeGeneration();
        for (;;) {
            try {
                byte[] frame = nativeReceive();
                if (nativeGeneration() != generation) { session.reset(); generation = nativeGeneration(); }
                int length = 0; while (length < frame.length && frame[length] != 0) length++;
                String response = session.handle(new String(frame, 0, length, StandardCharsets.US_ASCII));
                byte[] output = new byte[4096], payload = response.getBytes(StandardCharsets.US_ASCII);
                if (payload.length >= output.length) throw new IOException("response too large");
                System.arraycopy(payload, 0, output, 0, payload.length);
                nativeSend(output);
                System.out.println("SENT " + response.split(" ", 2)[0]); System.out.flush();
            } catch (IOException disconnected) {
                session.reset(); Thread.sleep(200);
            }
        }
    }
}
