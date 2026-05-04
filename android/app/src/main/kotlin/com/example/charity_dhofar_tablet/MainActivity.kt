package com.example.charity_dhofar_tablet

import android.content.Intent
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.mosambee"
    private val LOGIN_REQUEST_CODE = 1001
    private val PAYMENT_REQUEST_CODE = 1002

    // Same key used in runner_src PasswordToken.java
    // IMPORTANT: confirm this matches what Mosambee/bank provided for your environment.
    private val PASSWORD_TOKEN_AES_KEY_HEX =
        "C9DDC0BB57179060D9F2E01BE71D65C71D222A063F4DDA858FDC467B173BD146"

    private var loginAndPayResult: MethodChannel.Result? = null
    private var paymentRequestData: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "loginAndPay" -> {
                        val args = (call.arguments as? Map<*, *>) ?: run {
                            result.error("BAD_ARGS", "Arguments must be a map", null)
                            return@setMethodCallHandler
                        }

                        if (loginAndPayResult != null) {
                            result.error("BUSY", "A transaction is already in progress", null)
                            return@setMethodCallHandler
                        }

                        val pkg = args["packageName"]?.toString()?.trim().orEmpty()
                        val userName = args["userName"]?.toString()?.trim().orEmpty()
                        val partnerId = args["partnerId"]?.toString()?.trim().orEmpty()

                        // Preferred: pass PIN from Dart and generate passwordToken here
                        val pin = args["pin"]?.toString()
                        // Backward compatible: if you still pass precomputed token as "password"
                        val passwordFromDart = args["password"]?.toString()

                        if (pkg.isEmpty() || userName.isEmpty()) {
                            result.error("BAD_ARGS", "packageName and userName are required", null)
                            return@setMethodCallHandler
                        }

                        val passwordToken = when {
                            !pin.isNullOrBlank() -> generatePasswordToken(userName, pin)
                            !passwordFromDart.isNullOrBlank() -> passwordFromDart
                            else -> {
                                result.error("BAD_ARGS", "Either pin or password(token) must be provided", null)
                                return@setMethodCallHandler
                            }
                        }

                        val loginIntent = Intent().apply {
                            setPackage(pkg)
                            action = "com.mosambee.softpos.login"
                            putExtra("userName", userName)
                            putExtra("password", passwordToken)
                            if (partnerId.isNotEmpty()) putExtra("partnerId", partnerId)
                        }

                        loginAndPayResult = result
                        paymentRequestData = args.entries.associate { (k, v) -> k.toString() to v }

                        try {
                            showLoadingDialog("Launching Mosambee Login...")
                            startActivityForResult(loginIntent, LOGIN_REQUEST_CODE)
                        } catch (e: Exception) {
                            dismissLoadingDialog()
                            val payload = JSONObject()
                                .put("stage", "login")
                                .put("status", "failed")
                                .put("error", e.toString())
                                .toString()
                            loginAndPayResult?.success(payload)
                            loginAndPayResult = null
                            paymentRequestData = null
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            LOGIN_REQUEST_CODE -> handleLoginResult(data)
            PAYMENT_REQUEST_CODE -> handlePaymentResult(resultCode, data)
        }
    }

    private fun handleLoginResult(data: Intent?) {
        val sessionId = data?.getStringExtra("sessionId")?.trim().orEmpty()

        if (sessionId.isEmpty()) {
            dismissLoadingDialog()
            val payload = JSONObject()
                .put("stage", "login")
                .put("status", "failed")
                .put("message", "Login failed or cancelled (no sessionId)")
                .toString()

            loginAndPayResult?.success(payload)
            loginAndPayResult = null
            paymentRequestData = null
            return
        }

        val args = paymentRequestData ?: run {
            dismissLoadingDialog()
            val payload = JSONObject()
                .put("stage", "login")
                .put("status", "failed")
                .put("message", "Missing pending payment args")
                .toString()
            loginAndPayResult?.success(payload)
            loginAndPayResult = null
            paymentRequestData = null
            return
        }

        val pkg = args["packageName"]?.toString()?.trim().orEmpty()
        val amount = args["amount"]?.toString()?.trim().orEmpty()
        val mobNo = args["mobNo"]?.toString().orEmpty()
        val description = args["description"]?.toString().orEmpty()

        val paymentIntent = Intent().apply {
            setPackage(pkg)
            action = "com.mosambee.softpos.payment"
            putExtra("sessionId", sessionId)
            putExtra("amount", amount)
            if (mobNo.isNotEmpty()) putExtra("mobNo", mobNo)
            if (description.isNotEmpty()) putExtra("description", description)
        }

        try {
            updateLoadingDialogMessage("Starting Payment...")
            startActivityForResult(paymentIntent, PAYMENT_REQUEST_CODE)
        } catch (e: Exception) {
            dismissLoadingDialog()
            val payload = JSONObject()
                .put("stage", "payment")
                .put("status", "failed")
                .put("error", e.toString())
                .toString()

            loginAndPayResult?.success(payload)
            loginAndPayResult = null
            paymentRequestData = null
        }
    }

    private fun handlePaymentResult(resultCode: Int, data: Intent?) {
        dismissLoadingDialog()

        val receiptStr = data?.getStringExtra("receiptResponse") ?: "{}"
        val paymentResponseCode = data?.getStringExtra("paymentResponseCode") ?: ""
        val paymentDescription = data?.getStringExtra("paymentDescription") ?: ""
    
        val receiptJson = try {
            JSONObject(receiptStr)
        } catch (e: Exception) {
            JSONObject().put("raw", receiptStr)
        }
    
        // ✅ fallback to receiptResponse.responseCode if paymentResponseCode is missing
        val code = paymentResponseCode.trim().ifEmpty { receiptJson.optString("responseCode", "") }.trim()
        val isSuccess = (code == "0" || code == "00" || receiptJson.optString("result") == "success")
    
        val payload = JSONObject()
            .put("stage", "payment")
            .put("status", if (isSuccess) "success" else "failed")
            .put("paymentResponseCode", code)
            .put("paymentDescription", paymentDescription)
            .put("receiptResponse", receiptJson)   // ✅ object, not escaped string
            .put("resultCode", resultCode)
            .toString()
    
        Log.d("MosambeeDebug", "Payment payload: $payload")
        loginAndPayResult?.success(payload)
        loginAndPayResult = null
        paymentRequestData = null
    }
    

    // ---------------- runner_src PasswordToken logic ----------------

    private fun generatePasswordToken(userName: String, pin: String): String {
        val c1 = sha256Hex(pin)       // lowercase hex
        val c2 = sha256Hex(userName)  // lowercase hex
        val passToken = xorHex(c1, c2) // uppercase hex
        return aesEncryptAppendIvHex(PASSWORD_TOKEN_AES_KEY_HEX, passToken)
    }

    private fun sha256Hex(input: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val hash = md.digest(input.toByteArray(Charsets.UTF_8))
        return hash.joinToString("") { "%02x".format(it) } // lowercase
    }

    private fun xorHex(hex1: String, hex2: String): String {
        val b1 = hexToBytes(hex1)
        val b2 = hexToBytes(hex2)
        val out = ByteArray(b1.size)
        for (i in b1.indices) out[i] = (b1[i].toInt() xor b2[i].toInt()).toByte()
        return bytesToHexUpper(out) // uppercase
    }

    private fun aesEncryptAppendIvHex(keyHex: String, value: String): String {
        val keyBytes = hexToBytes(keyHex)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")

        val iv = ByteArray(cipher.blockSize)
        SecureRandom().nextBytes(iv)

        val skeySpec = SecretKeySpec(keyBytes, "AES")
        cipher.init(Cipher.ENCRYPT_MODE, skeySpec, IvParameterSpec(iv))

        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return bytesToHexUpper(encrypted) + bytesToHexUpper(iv) // encryptedHex + ivHex
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim()
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < clean.length) {
            out[i / 2] = clean.substring(i, i + 2).toInt(16).toByte()
            i += 2
        }
        return out
    }

    private fun bytesToHexUpper(bytes: ByteArray): String =
        bytes.joinToString("") { "%02X".format(it) }

    private fun showLoadingDialog(@Suppress("UNUSED_PARAMETER") message: String) = Unit

    private fun dismissLoadingDialog() = Unit

    private fun updateLoadingDialogMessage(@Suppress("UNUSED_PARAMETER") message: String) = Unit
}
