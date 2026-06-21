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

    // Same key used in runner_src PasswordToken.java.
    // Confirm this matches what Mosambee/bank provided for your environment.
    private val PASSWORD_TOKEN_AES_KEY_HEX =
        "C9DDC0BB57179060D9F2E01BE71D65C71D222A063F4DDA858FDC467B173BD146"

    private var loginResult: MethodChannel.Result? = null
    private var paymentResult: MethodChannel.Result? = null
    private var loginContinuesToPayment = false
    private var pendingPaymentArgs: Map<String, Any?>? = null
    private var preparedSessionId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepareLogin" -> handlePrepareLogin(call.arguments, result)
                    "payWithPreparedSession" -> handlePayWithPreparedSession(call.arguments, result)
                    "loginAndPay" -> handleLoginAndPay(call.arguments, result)
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

    private fun handlePrepareLogin(arguments: Any?, result: MethodChannel.Result) {
        if (preparedSessionId?.isNotBlank() == true) {
            result.success(
                JSONObject()
                    .put("stage", "login")
                    .put("status", "success")
                    .put("sessionReady", true)
                    .put("message", "Mosambee session already prepared")
                    .toString()
            )
            return
        }

        startLogin(arguments, result, continuesToPayment = false)
    }

    private fun handleLoginAndPay(arguments: Any?, result: MethodChannel.Result) {
        startLogin(arguments, result, continuesToPayment = true)
    }

    private fun handlePayWithPreparedSession(arguments: Any?, result: MethodChannel.Result) {
        val args = parseArgs(arguments, result) ?: return

        if (paymentResult != null || loginResult != null) {
            result.error("BUSY", "A Mosambee operation is already in progress", null)
            return
        }

        val sessionId = preparedSessionId?.trim().orEmpty()
        if (sessionId.isEmpty()) {
            result.success(
                JSONObject()
                    .put("stage", "payment")
                    .put("status", "failed")
                    .put("code", "NO_SESSION")
                    .put("message", "No prepared Mosambee login session")
                    .toString()
            )
            return
        }

        preparedSessionId = null
        startPayment(sessionId, args, result)
    }

    private fun startLogin(
        arguments: Any?,
        result: MethodChannel.Result,
        continuesToPayment: Boolean
    ) {
        val args = parseArgs(arguments, result) ?: return

        if (paymentResult != null || loginResult != null) {
            result.error("BUSY", "A Mosambee operation is already in progress", null)
            return
        }

        val pkg = args["packageName"]?.toString()?.trim().orEmpty()
        val userName = args["userName"]?.toString()?.trim().orEmpty()
        val partnerId = args["partnerId"]?.toString()?.trim().orEmpty()
        val pin = args["pin"]?.toString()
        val passwordFromDart = args["password"]?.toString()

        if (pkg.isEmpty() || userName.isEmpty()) {
            result.error("BAD_ARGS", "packageName and userName are required", null)
            return
        }

        val passwordToken = when {
            !pin.isNullOrBlank() -> generatePasswordToken(userName, pin)
            !passwordFromDart.isNullOrBlank() -> passwordFromDart
            else -> {
                result.error("BAD_ARGS", "Either pin or password(token) must be provided", null)
                return
            }
        }

        val loginIntent = Intent().apply {
            setPackage(pkg)
            action = "com.mosambee.softpos.login"
            putExtra("userName", userName)
            putExtra("password", passwordToken)
            if (partnerId.isNotEmpty()) putExtra("partnerId", partnerId)
        }

        loginResult = result
        loginContinuesToPayment = continuesToPayment
        pendingPaymentArgs = if (continuesToPayment) args else null

        try {
            showLoadingDialog("Launching Mosambee Login...")
            startActivityForResult(loginIntent, LOGIN_REQUEST_CODE)
        } catch (e: Exception) {
            dismissLoadingDialog()
            loginResult?.success(
                JSONObject()
                    .put("stage", "login")
                    .put("status", "failed")
                    .put("sessionReady", false)
                    .put("error", e.toString())
                    .toString()
            )
            clearLoginState()
        }
    }

    private fun handleLoginResult(data: Intent?) {
        dismissLoadingDialog()

        val activeResult = loginResult ?: return
        val sessionId = data?.getStringExtra("sessionId")?.trim().orEmpty()
        val responseCode = data?.getStringExtra("responseCode")?.trim().orEmpty()
        val description = data?.getStringExtra("description")?.trim().orEmpty()

        if (sessionId.isEmpty()) {
            activeResult.success(
                JSONObject()
                    .put("stage", "login")
                    .put("status", "failed")
                    .put("sessionReady", false)
                    .put("responseCode", responseCode)
                    .put("description", description)
                    .put("message", "Login failed or cancelled (no sessionId)")
                    .toString()
            )
            clearLoginState()
            return
        }

        if (!loginContinuesToPayment) {
            preparedSessionId = sessionId
            activeResult.success(
                JSONObject()
                    .put("stage", "login")
                    .put("status", "success")
                    .put("sessionReady", true)
                    .put("responseCode", responseCode)
                    .put("description", description)
                    .toString()
            )
            clearLoginState()
            return
        }

        val args = pendingPaymentArgs
        if (args == null) {
            activeResult.success(
                JSONObject()
                    .put("stage", "login")
                    .put("status", "failed")
                    .put("sessionReady", false)
                    .put("message", "Missing pending payment args")
                    .toString()
            )
            clearLoginState()
            return
        }

        paymentResult = activeResult
        clearLoginState()
        startPayment(sessionId, args, activeResult)
    }

    private fun startPayment(
        sessionId: String,
        args: Map<String, Any?>,
        result: MethodChannel.Result
    ) {
        val pkg = args["packageName"]?.toString()?.trim().orEmpty()
        val amount = args["amount"]?.toString()?.trim().orEmpty()
        val mobNo = args["mobNo"]?.toString().orEmpty()
        val description = args["description"]?.toString().orEmpty()

        if (pkg.isEmpty() || amount.isEmpty()) {
            result.error("BAD_ARGS", "packageName and amount are required", null)
            clearPaymentState()
            return
        }

        val paymentIntent = Intent().apply {
            setPackage(pkg)
            action = "com.mosambee.softpos.payment"
            putExtra("sessionId", sessionId)
            putExtra("amount", amount)
            if (mobNo.isNotEmpty()) putExtra("mobNo", mobNo)
            if (description.isNotEmpty()) putExtra("description", description)
        }

        paymentResult = result

        try {
            showLoadingDialog("Starting Payment...")
            startActivityForResult(paymentIntent, PAYMENT_REQUEST_CODE)
        } catch (e: Exception) {
            dismissLoadingDialog()
            paymentResult?.success(
                JSONObject()
                    .put("stage", "payment")
                    .put("status", "failed")
                    .put("error", e.toString())
                    .toString()
            )
            clearPaymentState()
        }
    }

    private fun handlePaymentResult(resultCode: Int, data: Intent?) {
        dismissLoadingDialog()

        val activeResult = paymentResult ?: return
        val receiptStr = data?.getStringExtra("receiptResponse") ?: "{}"
        val responseCode = data?.getStringExtra("responseCode")?.trim().orEmpty()
        val paymentResponseCode = data?.getStringExtra("paymentResponseCode")?.trim().orEmpty()
        val paymentDescription = data?.getStringExtra("paymentDescription") ?: ""

        val receiptJson = try {
            JSONObject(receiptStr)
        } catch (e: Exception) {
            JSONObject().put("raw", receiptStr)
        }

        val receiptResponseCode = receiptJson.optString("responseCode", "").trim()
        val code = paymentResponseCode.ifEmpty { receiptResponseCode }
        val isSuccess = when {
            paymentResponseCode.isNotEmpty() -> paymentResponseCode == "0" || paymentResponseCode == "00"
            receiptResponseCode.isNotEmpty() && !receiptResponseCode.equals("NA", ignoreCase = true) ->
                receiptResponseCode == "0" || receiptResponseCode == "00"
            else -> receiptJson.optString("result", "").equals("success", ignoreCase = true)
        }

        val payload = JSONObject()
            .put("stage", "payment")
            .put("status", if (isSuccess) "success" else "failed")
            .put("responseCode", responseCode)
            .put("paymentResponseCode", code)
            .put("paymentDescription", paymentDescription)
            .put("receiptResponse", receiptJson)
            .put("resultCode", resultCode)
            .toString()

        Log.d("MosambeeDebug", "Payment payload: $payload")
        activeResult.success(payload)
        clearPaymentState()
    }

    private fun parseArgs(arguments: Any?, result: MethodChannel.Result): Map<String, Any?>? {
        val args = arguments as? Map<*, *> ?: run {
            result.error("BAD_ARGS", "Arguments must be a map", null)
            return null
        }

        return args.entries.associate { (key, value) -> key.toString() to value }
    }

    private fun clearLoginState() {
        loginResult = null
        loginContinuesToPayment = false
        pendingPaymentArgs = null
    }

    private fun clearPaymentState() {
        paymentResult = null
    }

    // ---------------- runner_src PasswordToken logic ----------------

    private fun generatePasswordToken(userName: String, pin: String): String {
        val c1 = sha256Hex(pin)
        val c2 = sha256Hex(userName)
        val passToken = xorHex(c1, c2)
        return aesEncryptAppendIvHex(PASSWORD_TOKEN_AES_KEY_HEX, passToken)
    }

    private fun sha256Hex(input: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val hash = md.digest(input.toByteArray(Charsets.UTF_8))
        return hash.joinToString("") { "%02x".format(it) }
    }

    private fun xorHex(hex1: String, hex2: String): String {
        val b1 = hexToBytes(hex1)
        val b2 = hexToBytes(hex2)
        val out = ByteArray(b1.size)
        for (i in b1.indices) out[i] = (b1[i].toInt() xor b2[i].toInt()).toByte()
        return bytesToHexUpper(out)
    }

    private fun aesEncryptAppendIvHex(keyHex: String, value: String): String {
        val keyBytes = hexToBytes(keyHex)
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")

        val iv = ByteArray(cipher.blockSize)
        SecureRandom().nextBytes(iv)

        val skeySpec = SecretKeySpec(keyBytes, "AES")
        cipher.init(Cipher.ENCRYPT_MODE, skeySpec, IvParameterSpec(iv))

        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return bytesToHexUpper(encrypted) + bytesToHexUpper(iv)
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
}
