package com.blackforest.app.blackforest_app

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val BLUETOOTH_CHANNEL = "blackforest.app/bluetooth"
    private val LOCATION_CHANNEL = "blackforest.app/location"
    private val VOLUME_CHANNEL = "blackforest.app/volume"
    private val REQUEST_ENABLE_BT = 1

    private var isAlarmActive = false
    private var originalAlarmVolume: Int? = null
    private var originalMusicVolume: Int? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var volumeEnforceRunnable: Runnable? = null
    private var volumeContentObserver: ContentObserver? = null

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
                "startAlarmMode" -> {
                    try {
                        startAlarmMode()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "stopAlarmMode" -> {
                    try {
                        stopAlarmMode()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "wakeScreen" -> {
                    try {
                        wakeScreenAndShowOverLock()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
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

    private fun startAlarmMode() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (!isAlarmActive) {
            try {
                originalAlarmVolume = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
                originalMusicVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            } catch (e: Exception) {
                // Ignore
            }
        }
        isAlarmActive = true

        // Enforce max volume on alarm & music stream
        enforceMaxVolume()

        // Turn on screen and show over lockscreen
        wakeScreenAndShowOverLock()

        // Continuous enforcement loop
        startVolumeEnforcer()
    }

    private fun stopAlarmMode() {
        isAlarmActive = false
        stopVolumeEnforcer()

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            originalAlarmVolume?.let {
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, it, 0)
            }
            originalMusicVolume?.let {
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, it, 0)
            }
        } catch (e: Exception) {
            // Ignore
        }
        originalAlarmVolume = null
        originalMusicVolume = null

        releaseWakeLock()
    }

    private fun enforceMaxVolume() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val maxAlarm = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            val currentAlarm = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
            if (currentAlarm < maxAlarm) {
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, maxAlarm, 0)
            }

            val maxMusic = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val currentMusic = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (currentMusic < maxMusic) {
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxMusic, 0)
            }
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun startVolumeEnforcer() {
        stopVolumeEnforcer()

        // 1. Periodic check runnable every 200ms
        volumeEnforceRunnable = object : Runnable {
            override fun run() {
                if (isAlarmActive) {
                    enforceMaxVolume()
                    mainHandler.postDelayed(this, 200)
                }
            }
        }
        volumeEnforceRunnable?.let { mainHandler.post(it) }

        // 2. ContentObserver on system settings to catch instant volume changes
        try {
            volumeContentObserver = object : ContentObserver(mainHandler) {
                override fun onChange(selfChange: Boolean) {
                    super.onChange(selfChange)
                    if (isAlarmActive) {
                        enforceMaxVolume()
                    }
                }
            }
            volumeContentObserver?.let {
                contentResolver.registerContentObserver(
                    Settings.System.CONTENT_URI,
                    true,
                    it
                )
            }
        } catch (e: Exception) {
            // Content observer registration failed
        }
    }

    private fun stopVolumeEnforcer() {
        volumeEnforceRunnable?.let {
            mainHandler.removeCallbacks(it)
            volumeEnforceRunnable = null
        }
        volumeContentObserver?.let {
            try {
                contentResolver.unregisterContentObserver(it)
            } catch (e: Exception) {
                // Ignore
            }
            volumeContentObserver = null
        }
    }

    private fun wakeScreenAndShowOverLock() {
        runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(true)
                    setTurnScreenOn(true)
                }
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )

                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                if (wakeLock == null) {
                    @Suppress("DEPRECATION")
                    wakeLock = powerManager.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                        "blackforest:WaiterAlertWakeLock"
                    )
                }
                if (wakeLock?.isHeld == false) {
                    wakeLock?.acquire(5 * 60 * 1000L /* 5 minutes max */)
                }
            } catch (e: Exception) {
                // Ignore wake lock issues
            }
        }
    }

    private fun releaseWakeLock() {
        runOnUiThread {
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
                wakeLock = null
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } catch (e: Exception) {
                // Ignore
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isAlarmActive) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP,
                KeyEvent.KEYCODE_VOLUME_DOWN,
                KeyEvent.KEYCODE_VOLUME_MUTE -> {
                    // Suppress volume keys so waiter cannot lower/mute the alarm
                    enforceMaxVolume()
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        stopAlarmMode()
        super.onDestroy()
    }
}
