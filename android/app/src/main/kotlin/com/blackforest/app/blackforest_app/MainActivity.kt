package com.blackforest.app.blackforest_app

import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.provider.Settings
import android.media.AudioManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val BLUETOOTH_CHANNEL = "blackforest.app/bluetooth"
    private val LOCATION_CHANNEL = "blackforest.app/location"
    private val VOLUME_CHANNEL = "blackforest.app/volume"
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL).setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            when (call.method) {
                "getAlarmVolume" -> {
                    try {
                        val volume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
                        result.success(volume)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "getMaxAlarmVolume" -> {
                    try {
                        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                        result.success(maxVolume)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "setAlarmVolume" -> {
                    try {
                        val volume = call.argument<Int>("volume")
                        if (volume != null) {
                            audioManager.setStreamVolume(AudioManager.STREAM_ALARM, volume, 0)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Volume argument is null", null)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "getMusicVolume" -> {
                    try {
                        val volume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        result.success(volume)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "getMaxMusicVolume" -> {
                    try {
                        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        result.success(maxVolume)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "setMusicVolume" -> {
                    try {
                        val volume = call.argument<Int>("volume")
                        if (volume != null) {
                            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, volume, 0)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGUMENT", "Volume argument is null", null)
                        }
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
