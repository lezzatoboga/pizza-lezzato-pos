package com.pizzalezzato.pos;

import android.os.Bundle;
import android.view.WindowManager;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // Plugin lokal harus didaftarkan sebelum super.onCreate().
        registerPlugin(EscPosPrinterPlugin.class);
        super.onCreate(savedInstanceState);
        // Layar kasir tidak mati sendiri selama aplikasi terbuka.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
}
