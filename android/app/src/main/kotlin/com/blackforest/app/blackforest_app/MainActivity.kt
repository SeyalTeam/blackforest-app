package com.blackforest.app.blackforest_app

import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val BLUETOOTH_CHANNEL = "blackforest.app/bluetooth"
    private val LOCATION_CHANNEL = "blackforest.app/location"
    private val REQUEST_ENABLE_BT = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "turnOnBluetooth") {
                val bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
                if (bluetoothAdapter == null) {
                    result.error("UNAVAILABLE", "Bluetooth not available", null)
                } else if (!bluetoothAdapter.isEnabled) {
                    val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    activity.startActivityForResult(enableBtIntent, REQUEST_ENABLE_BT)
                    result.success(true)
                } else {
                    result.success(true)
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCATION_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "turnOnLocation") {
                val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                startActivity(intent)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
