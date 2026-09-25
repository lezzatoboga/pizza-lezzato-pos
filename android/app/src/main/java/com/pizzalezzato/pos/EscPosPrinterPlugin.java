package com.pizzalezzato.pos;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothSocket;
import android.content.Context;
import android.os.Build;
import android.util.Base64;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.IOException;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Cetak ESC/POS mentah ke printer thermal Bluetooth klasik (SPP), mis. Iware MP58SB.
 *
 * - listPairedPrinters(): perangkat Bluetooth yang sudah dipasangkan (pairing) di Android.
 * - print({ address, data }): kirim byte (base64) ke printer dengan alamat MAC tertentu,
 *   sehingga tiket dapur & struk bisa diarahkan ke printer yang berbeda.
 *
 * Setiap cetakan membuka sambungan baru lalu menutupnya — sedikit lebih lambat, tapi tidak ada
 * data yang hilang diam-diam karena sambungan lama sudah diputus printer. Cetakan ke printer
 * yang sama diantrikan; printer berbeda berjalan paralel.
 */
@CapacitorPlugin(
    name = "EscPosPrinter",
    permissions = { @Permission(alias = "bluetooth", strings = { Manifest.permission.BLUETOOTH_CONNECT }) }
)
public class EscPosPrinterPlugin extends Plugin {

    private static final UUID SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");
    // Dikirim bertahap supaya buffer printer murah tidak meluap (terutama gambar logo).
    private static final int CHUNK_SIZE = 1024;
    private static final long CHUNK_DELAY_MS = 20;
    // Beri waktu printer menerima sisa data sebelum sambungan ditutup.
    private static final long CLOSE_DELAY_MS = 600;

    private final Map<String, ExecutorService> queues = new HashMap<>();

    // BLUETOOTH_CONNECT hanya ada (dan wajib diminta) di Android 12 ke atas.
    private boolean needsPermission() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && getPermissionState("bluetooth") != PermissionState.GRANTED;
    }

    private BluetoothAdapter adapter() {
        BluetoothManager manager = (BluetoothManager) getContext().getSystemService(Context.BLUETOOTH_SERVICE);
        return manager == null ? null : manager.getAdapter();
    }

    // Mengembalikan adapter siap pakai, atau menolak panggilan dengan pesan yang jelas.
    private BluetoothAdapter readyAdapter(PluginCall call) {
        BluetoothAdapter adapter = adapter();
        if (adapter == null) {
            call.reject("Perangkat ini tidak punya Bluetooth", "NO_BLUETOOTH");
            return null;
        }
        if (!adapter.isEnabled()) {
            call.reject("Bluetooth mati. Nyalakan Bluetooth di tablet terlebih dahulu.", "BLUETOOTH_OFF");
            return null;
        }
        return adapter;
    }

    // ------------------------------------------------------------------ daftar printer

    @PluginMethod
    public void listPairedPrinters(PluginCall call) {
        if (needsPermission()) {
            requestPermissionForAlias("bluetooth", call, "listPermissionCallback");
            return;
        }
        doList(call);
    }

    @PermissionCallback
    private void listPermissionCallback(PluginCall call) {
        if (needsPermission()) {
            call.reject("Izin Bluetooth ditolak. Izinkan di Pengaturan Android → Aplikasi.", "PERMISSION_DENIED");
            return;
        }
        doList(call);
    }

    @SuppressLint("MissingPermission")
    private void doList(PluginCall call) {
        BluetoothAdapter adapter = readyAdapter(call);
        if (adapter == null) return;

        JSArray printers = new JSArray();
        for (BluetoothDevice device : adapter.getBondedDevices()) {
            JSObject item = new JSObject();
            item.put("name", device.getName() != null ? device.getName() : device.getAddress());
            item.put("address", device.getAddress());
            printers.put(item);
        }
        JSObject result = new JSObject();
        result.put("printers", printers);
        call.resolve(result);
    }

    // ------------------------------------------------------------------ cetak

    @PluginMethod
    public void print(PluginCall call) {
        if (needsPermission()) {
            requestPermissionForAlias("bluetooth", call, "printPermissionCallback");
            return;
        }
        doPrint(call);
    }

    @PermissionCallback
    private void printPermissionCallback(PluginCall call) {
        if (needsPermission()) {
            call.reject("Izin Bluetooth ditolak. Izinkan di Pengaturan Android → Aplikasi.", "PERMISSION_DENIED");
            return;
        }
        doPrint(call);
    }

    private void doPrint(PluginCall call) {
        String address = call.getString("address");
        String data = call.getString("data");
        if (address == null || data == null) {
            call.reject("Alamat printer dan data cetak wajib diisi", "INVALID_ARGUMENT");
            return;
        }
        if (!BluetoothAdapter.checkBluetoothAddress(address)) {
            call.reject("Alamat printer tidak valid: " + address, "INVALID_ARGUMENT");
            return;
        }

        final byte[] bytes;
        try {
            bytes = Base64.decode(data, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            call.reject("Data cetak tidak valid", "INVALID_ARGUMENT");
            return;
        }

        BluetoothAdapter adapter = readyAdapter(call);
        if (adapter == null) return;

        queueFor(address).execute(() -> {
            try {
                send(adapter, address, bytes);
                call.resolve();
            } catch (IOException e) {
                call.reject("Gagal terhubung ke printer. Pastikan printer menyala dan dalam jangkauan. (" + e.getMessage() + ")", "PRINT_FAILED");
            } catch (SecurityException e) {
                call.reject("Izin Bluetooth belum diberikan", "PERMISSION_DENIED");
            }
        });
    }

    private synchronized ExecutorService queueFor(String address) {
        ExecutorService queue = queues.get(address);
        if (queue == null) {
            queue = Executors.newSingleThreadExecutor();
            queues.put(address, queue);
        }
        return queue;
    }

    @SuppressLint("MissingPermission")
    private void send(BluetoothAdapter adapter, String address, byte[] bytes) throws IOException {
        BluetoothDevice device = adapter.getRemoteDevice(address);
        BluetoothSocket socket = connect(device);
        try {
            OutputStream out = socket.getOutputStream();
            for (int offset = 0; offset < bytes.length; offset += CHUNK_SIZE) {
                out.write(bytes, offset, Math.min(CHUNK_SIZE, bytes.length - offset));
                out.flush();
                sleep(CHUNK_DELAY_MS);
            }
            sleep(CLOSE_DELAY_MS);
        } finally {
            try {
                socket.close();
            } catch (IOException ignored) {
                // sambungan sudah tertutup
            }
        }
    }

    // Sambungan aman lebih dulu; sebagian printer murah hanya menerima sambungan "insecure".
    @SuppressLint("MissingPermission")
    private BluetoothSocket connect(BluetoothDevice device) throws IOException {
        BluetoothSocket socket = device.createRfcommSocketToServiceRecord(SPP_UUID);
        try {
            socket.connect();
            return socket;
        } catch (IOException secureFailed) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // abaikan
            }
            BluetoothSocket fallback = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID);
            fallback.connect();
            return fallback;
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
