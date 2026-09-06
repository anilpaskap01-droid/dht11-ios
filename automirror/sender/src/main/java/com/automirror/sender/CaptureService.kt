package com.automirror.sender

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.io.DataOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class CaptureService : Service() {
    private val running = AtomicBoolean(false)
    private val executor = Executors.newCachedThreadPool()
    private val clientLock = Any()
    private val csdReady = CountDownLatch(1)

    private var mediaProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var serverSocket: ServerSocket? = null
    private var announcerSocket: DatagramSocket? = null
    private var clientSocket: Socket? = null
    private var clientOut: DataOutputStream? = null

    @Volatile private var csd0 = ByteArray(0)
    @Volatile private var csd1 = ByteArray(0)
    @Volatile private var videoWidth = 720
    @Volatile private var videoHeight = 1280
    @Volatile private var densityDpi = 320

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startProjectionForeground()

        if (running.get()) return START_STICKY
        val source = intent ?: return START_NOT_STICKY
        val resultCode = source.getIntExtra(EXTRA_RESULT_CODE, 0)
        val resultData = getIntentExtra(source, EXTRA_RESULT_DATA) ?: return START_NOT_STICKY

        try {
            startProjection(resultCode, resultData)
        } catch (t: Throwable) {
            Log.e(TAG, "Projection start failed", t)
            stopSelf()
        }
        return START_STICKY
    }

    private fun startProjectionForeground() {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("AutoMirror yayın yapıyor")
            .setContentText("Telefon ekranı yerel ağdaki Head Unit'e aktarılıyor")
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startProjection(resultCode: Int, resultData: Intent) {
        val projectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = projectionManager.getMediaProjection(resultCode, resultData)
            ?: throw IllegalStateException("Ekran yakalama izni alınamadı")
        mediaProjection = projection

        projectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }.also { projection.registerCallback(it, Handler(Looper.getMainLooper())) }

        calculateCaptureSize()
        setupEncoderAndVirtualDisplay(projection)
        running.set(true)

        executor.execute { drainEncoderLoop() }
        executor.execute { tcpServerLoop() }
        executor.execute { discoveryAnnouncerLoop() }
    }

    private fun calculateCaptureSize() {
        val dm = resources.displayMetrics
        val rawW = dm.widthPixels.coerceAtLeast(2)
        val rawH = dm.heightPixels.coerceAtLeast(2)
        densityDpi = dm.densityDpi

        val maxSide = 1280.0
        val scale = if (maxOf(rawW, rawH) > maxSide) maxSide / maxOf(rawW, rawH) else 1.0
        videoWidth = even((rawW * scale).toInt().coerceAtLeast(2))
        videoHeight = even((rawH * scale).toInt().coerceAtLeast(2))
    }

    private fun even(v: Int) = if (v % 2 == 0) v else v - 1

    private fun setupEncoderAndVirtualDisplay(projection: MediaProjection) {
        val format = MediaFormat.createVideoFormat(MIME, videoWidth, videoHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            if (Build.VERSION.SDK_INT >= 30) {
                runCatching { setInteger(MediaFormat.KEY_LOW_LATENCY, 1) }
            }
        }

        val codec = MediaCodec.createEncoderByType(MIME)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        encoder = codec
        encoderInputSurface = surface
        virtualDisplay = projection.createVirtualDisplay(
            "AutoMirrorProjection",
            videoWidth,
            videoHeight,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            null
        )
    }

    private fun drainEncoderLoop() {
        val codec = encoder ?: return
        val info = MediaCodec.BufferInfo()

        while (running.get()) {
            try {
                when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outFormat = codec.outputFormat
                        csd0 = outFormat.getByteBuffer("csd-0").copyRemaining()
                        csd1 = outFormat.getByteBuffer("csd-1").copyRemaining()
                        csdReady.countDown()
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (index >= 0) {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0 &&
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        ) {
                            val data = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(data)
                            sendFrame(data, info.presentationTimeUs, info.flags)
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            } catch (t: Throwable) {
                if (running.get()) Log.e(TAG, "Encoder loop failed", t)
                break
            }
        }
    }

    private fun tcpServerLoop() {
        try {
            ServerSocket().use { server ->
                server.reuseAddress = true
                server.bind(InetSocketAddress(STREAM_PORT))
                serverSocket = server

                while (running.get()) {
                    val socket = try { server.accept() } catch (_: IOException) { break }
                    socket.tcpNoDelay = true
                    socket.keepAlive = true

                    if (!csdReady.await(8, TimeUnit.SECONDS)) {
                        socket.close()
                        continue
                    }

                    val out = DataOutputStream(socket.getOutputStream())
                    try {
                        writeHeader(out)
                        synchronized(clientLock) {
                            closeClientLocked()
                            clientSocket = socket
                            clientOut = out
                        }
                        requestKeyFrame()
                    } catch (_: Throwable) {
                        runCatching { socket.close() }
                    }
                }
            }
        } catch (t: Throwable) {
            if (running.get()) Log.e(TAG, "TCP server failed", t)
        }
    }

    private fun writeHeader(out: DataOutputStream) {
        out.writeInt(MAGIC)
        out.writeInt(PROTOCOL_VERSION)
        out.writeInt(videoWidth)
        out.writeInt(videoHeight)
        out.writeInt(csd0.size)
        out.write(csd0)
        out.writeInt(csd1.size)
        out.write(csd1)
        out.flush()
    }

    private fun sendFrame(data: ByteArray, ptsUs: Long, flags: Int) {
        synchronized(clientLock) {
            val out = clientOut ?: return
            try {
                out.writeInt(data.size)
                out.writeLong(ptsUs)
                out.writeInt(flags)
                out.write(data)
                out.flush()
            } catch (_: IOException) {
                closeClientLocked()
            }
        }
    }

    private fun requestKeyFrame() {
        val b = Bundle().apply {
            putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
        }
        runCatching { encoder?.setParameters(b) }
    }

    private fun discoveryAnnouncerLoop() {
        try {
            DatagramSocket().use { socket ->
                announcerSocket = socket
                socket.broadcast = true
                val payload = "AUTOMIRROR|$PROTOCOL_VERSION|$STREAM_PORT".toByteArray(Charsets.UTF_8)

                while (running.get()) {
                    val addresses = broadcastAddresses()
                    for (address in addresses) {
                        runCatching {
                            socket.send(DatagramPacket(payload, payload.size, address, DISCOVERY_PORT))
                        }
                    }
                    Thread.sleep(1000)
                }
            }
        } catch (t: Throwable) {
            if (running.get()) Log.e(TAG, "Discovery announcer failed", t)
        }
    }

    private fun broadcastAddresses(): Set<InetAddress> {
        val result = linkedSetOf<InetAddress>()
        runCatching { result += InetAddress.getByName("255.255.255.255") }
        runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val ni = interfaces.nextElement()
                if (!ni.isUp || ni.isLoopback) continue
                ni.interfaceAddresses.forEach { ia -> ia.broadcast?.let { result += it } }
            }
        }
        return result
    }

    private fun closeClientLocked() {
        runCatching { clientOut?.close() }
        runCatching { clientSocket?.close() }
        clientOut = null
        clientSocket = null
    }

    override fun onDestroy() {
        running.set(false)
        runCatching { announcerSocket?.close() }
        runCatching { serverSocket?.close() }
        synchronized(clientLock) { closeClientLocked() }

        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { encoderInputSurface?.release() }
        encoderInputSurface = null
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        encoder = null

        projectionCallback?.let { callback -> runCatching { mediaProjection?.unregisterCallback(callback) } }
        runCatching { mediaProjection?.stop() }
        mediaProjection = null

        executor.shutdownNow()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "AutoMirror ekran yayını", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun getIntentExtra(intent: Intent, key: String): Intent? {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(key, Intent::class.java)
        } else {
            intent.getParcelableExtra(key)
        }
    }

    private fun ByteBuffer?.copyRemaining(): ByteArray {
        if (this == null) return ByteArray(0)
        val duplicate = duplicate()
        val out = ByteArray(duplicate.remaining())
        duplicate.get(out)
        return out
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        private const val TAG = "AutoMirrorSender"
        private const val CHANNEL_ID = "automirror_projection"
        private const val NOTIFICATION_ID = 42
        private const val MIME = "video/avc"
        private const val STREAM_PORT = 8989
        private const val DISCOVERY_PORT = 8988
        private const val MAGIC = 0x414D4952
        private const val PROTOCOL_VERSION = 1
    }
}
