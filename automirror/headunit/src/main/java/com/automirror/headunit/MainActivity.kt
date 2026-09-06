package com.automirror.headunit

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.DataInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var surfaceView: SurfaceView
    private lateinit var overlay: LinearLayout
    private lateinit var status: TextView
    private lateinit var ipInput: EditText

    private val running = AtomicBoolean(false)
    private val connected = AtomicBoolean(false)
    private val executor = Executors.newCachedThreadPool()
    private var streamSocket: Socket? = null
    private var discoverySocket: DatagramSocket? = null
    private var decoder: MediaCodec? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    @Volatile private var surfaceReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterImmersive()

        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this).also {
            it.holder.addCallback(this)
            it.setOnClickListener { toggleOverlay() }
        }
        root.addView(surfaceView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))

        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(14), dp(20), dp(14))
            setBackgroundColor(0xB3000000.toInt())
        }

        status = TextView(this).apply {
            text = "AutoMirror: telefon aranıyor…"
            setTextColor(Color.WHITE)
            textSize = 18f
        }

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        ipInput = EditText(this).apply {
            hint = "Telefon IP (örn. 192.168.43.1)"
            setHintTextColor(Color.LTGRAY)
            setTextColor(Color.WHITE)
            setSingleLine(true)
            setBackgroundColor(0x33000000)
        }

        val connect = Button(this).apply {
            text = "BAĞLAN"
            setOnClickListener {
                val ip = ipInput.text.toString().trim()
                if (ip.isNotEmpty()) connectTo(InetAddress.getByName(ip))
            }
        }

        val retry = Button(this).apply {
            text = "OTOMATİK ARA"
            setOnClickListener { startDiscovery() }
        }

        row.addView(ipInput, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(connect, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        row.addView(retry, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        overlay.addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        overlay.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        root.addView(overlay, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP
        ))

        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        running.set(true)
        acquireMulticastLock()
        if (surfaceReady && !connected.get()) startDiscovery()
    }

    override fun onPause() {
        super.onPause()
        running.set(false)
        closeNetwork()
        releaseDecoder()
        releaseMulticastLock()
    }

    override fun onDestroy() {
        running.set(false)
        closeNetwork()
        releaseDecoder()
        releaseMulticastLock()
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        if (running.get() && !connected.get()) startDiscovery()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        closeNetwork()
        releaseDecoder()
    }

    private fun startDiscovery() {
        if (!running.get() || connected.get() || !surfaceReady) return
        updateStatus("AutoMirror: telefon aranıyor…")
        executor.execute {
            try {
                discoverySocket?.close()
                val socket = DatagramSocket(null).apply {
                    reuseAddress = true
                    broadcast = true
                    bind(InetSocketAddress(DISCOVERY_PORT))
                }
                discoverySocket = socket
                val buffer = ByteArray(256)

                while (running.get() && !connected.get()) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    val message = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    if (message.startsWith("AUTOMIRROR|")) {
                        connectTo(packet.address)
                        return@execute
                    }
                }
            } catch (t: Throwable) {
                if (running.get() && !connected.get()) updateStatus("Otomatik arama bekliyor — gerekirse telefon IP'sini yaz")
            }
        }
    }

    private fun connectTo(address: InetAddress) {
        if (!running.get() || !surfaceReady || !connected.compareAndSet(false, true)) return
        updateStatus("Bağlanıyor: ${address.hostAddress}")
        discoverySocket?.close()

        executor.execute {
            try {
                val socket = Socket()
                socket.tcpNoDelay = true
                socket.keepAlive = true
                socket.connect(InetSocketAddress(address, STREAM_PORT), 5000)
                streamSocket = socket
                playStream(socket)
            } catch (t: Throwable) {
                connected.set(false)
                releaseDecoder()
                streamSocket?.runCatching { close() }
                streamSocket = null
                updateStatus("Bağlantı kesildi — yeniden aranıyor")
                if (running.get()) {
                    Thread.sleep(800)
                    startDiscovery()
                }
            }
        }
    }

    private fun playStream(socket: Socket) {
        val input = DataInputStream(socket.getInputStream())
        val magic = input.readInt()
        val version = input.readInt()
        if (magic != MAGIC || version != PROTOCOL_VERSION) error("Protocol mismatch")

        val width = input.readInt()
        val height = input.readInt()
        val csd0 = readBlob(input, 512 * 1024)
        val csd1 = readBlob(input, 512 * 1024)

        val surface = surfaceView.holder.surface
        if (!surface.isValid) error("Surface unavailable")

        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            if (csd0.isNotEmpty()) setByteBuffer("csd-0", ByteBuffer.wrap(csd0))
            if (csd1.isNotEmpty()) setByteBuffer("csd-1", ByteBuffer.wrap(csd1))
            if (Build.VERSION.SDK_INT >= 30) {
                runCatching { setInteger(MediaFormat.KEY_LOW_LATENCY, 1) }
            }
        }

        val codec = MediaCodec.createDecoderByType(MIME)
        codec.configure(format, surface, null, 0)
        codec.start()
        decoder = codec

        updateStatus("Bağlandı — ${width}×${height} / dokun: menü")
        runOnUiThread { overlay.visibility = View.GONE }

        val outInfo = MediaCodec.BufferInfo()
        while (running.get() && connected.get()) {
            val size = input.readInt()
            val ptsUs = input.readLong()
            val flags = input.readInt()
            if (size <= 0 || size > MAX_FRAME_SIZE) error("Invalid frame size: $size")
            val data = ByteArray(size)
            input.readFully(data)

            var queued = false
            while (!queued && running.get()) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    codec.getInputBuffer(inIndex)?.apply {
                        clear()
                        put(data)
                    }
                    codec.queueInputBuffer(inIndex, 0, data.size, ptsUs, flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    queued = true
                }
                drainDecoder(codec, outInfo)
            }
            drainDecoder(codec, outInfo)
        }
    }

    private fun drainDecoder(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            when (val outIndex = codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                else -> if (outIndex >= 0) codec.releaseOutputBuffer(outIndex, true) else return
            }
        }
    }

    private fun readBlob(input: DataInputStream, max: Int): ByteArray {
        val size = input.readInt()
        if (size < 0 || size > max) error("Invalid blob size")
        return ByteArray(size).also { input.readFully(it) }
    }

    private fun updateStatus(text: String) {
        runOnUiThread {
            status.text = text
            overlay.visibility = View.VISIBLE
        }
    }

    private fun toggleOverlay() {
        overlay.visibility = if (overlay.visibility == View.VISIBLE) View.GONE else View.VISIBLE
    }

    private fun closeNetwork() {
        connected.set(false)
        runCatching { discoverySocket?.close() }
        discoverySocket = null
        runCatching { streamSocket?.close() }
        streamSocket = null
    }

    private fun releaseDecoder() {
        val d = decoder ?: return
        decoder = null
        runCatching { d.stop() }
        runCatching { d.release() }
    }

    private fun acquireMulticastLock() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("AutoMirrorDiscovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        runCatching { multicastLock?.release() }
        multicastLock = null
    }

    private fun enterImmersive() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.apply {
                hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                )
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val MIME = "video/avc"
        private const val STREAM_PORT = 8989
        private const val DISCOVERY_PORT = 8988
        private const val MAGIC = 0x414D4952
        private const val PROTOCOL_VERSION = 1
        private const val MAX_FRAME_SIZE = 4 * 1024 * 1024
    }
}
