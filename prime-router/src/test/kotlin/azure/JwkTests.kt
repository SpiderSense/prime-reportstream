package gov.cdc.prime.router.azure

import Jwk
import com.fasterxml.jackson.databind.node.ArrayNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.github.kittinunf.fuel.util.decodeBase64
import com.nimbusds.jose.jwk.JWK
import com.nimbusds.jose.jwk.KeyType
import java.math.BigInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class JwkTests {
    val pemPublicESKey = """
-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE0ks/RiTQ82tMW4UEQu0LLDqqEEcj6yce
ZF5YuUU+IqOKaMAu4/tsbyE+hM4WDjZYG6cSnYKoRhOoam4oHFernOLOkbJKzzC/
5xzBqTIGx6SbmlcrPFPDjcJ8fn8CThVo
-----END PUBLIC KEY-----
    """.trimIndent()

    val affineX = "0ks_RiTQ82tMW4UEQu0LLDqqEEcj6yceZF5YuUU-IqOKaMAu4_tsbyE-hM4WDjZY"
    val affineY = "G6cSnYKoRhOoam4oHFernOLOkbJKzzC_5xzBqTIGx6SbmlcrPFPDjcJ8fn8CThVo"
    val ecPublicKeyStr = """
    {
         "kid": "1234",
         "kty":"EC",
         "crv":"P-384",
         "x":"$affineX",
         "y":"$affineY"
    }
    """.trimIndent()

    val ecPrivateKey = """
    {
         "kid": "1234",
         "kty":"EC",
         "d":"ty7q_3nZCTaY80-69YHJ18cN2vC1lRIuULMeKvhpg6C24fxCw_vHjHlF80EzcTX7",
         "crv":"P-384",
         "x":"$affineX",
         "y":"$affineY"
    }
    """.trimIndent()

    val modulus = "xJRuufBk_axjyO1Kpy5uwmnAY0VUhCzG8G4OiDVgnaXeLMzj91bcQdYOMQ_82PTGrUbck3qSFXbug_Ljj8NZDT0J1ZSKv8Oce-GdkeNzA5W9yvChvorGotAUWMS7_EXXxz8mjlrwu6kyKfCpuJAMg5VrZaYA0nAlv-e7zoRE9pQ0VHNrEaj6Uikw3M02oVHUNiRtL5Y5tYyz_yRBauVLPdHf5Yf-cZeO2x02qFSGcl_2EzWZcGb6PkQZ_9QeOq_iJ9h-NU_wb9lnbebnBhPGAyc1-_9vnFlFzkH2lt0BVtfhW0E4ieKkntbC0QFxNu91Gf4jfFmsOAsCf3UpVqWIQw"
    val exponent = "AQAB"
    val rsaPublicKeyStr = """
    {
        "kty":"RSA",
        "kid":"11209921-860e-4b6d-8d7e-adc8778e1c6c",
        "n": "$modulus",
        "e": "$exponent"
    }
    """.trimIndent()

    val jwkString = """
              { "kty": "ES",
                "use": "sig",
                "kid": "ignore.REDOX",
                 "x5c": [ "a", "b", "c" ]
              }
        """.trimIndent()

    val jwk = Jwk(kty ="ES", x = "x", y = "y", crv = "crv", kid = "myId", x5c = listOf("a", "b"))

    @Test
    fun `test convert to Jwk obj`() {
        val obj: Jwk = jacksonObjectMapper().readValue(jwkString, Jwk::class.java)
        assertNotNull(obj)
        assertEquals("ES", obj.kty)
        assertEquals("ignore.REDOX", obj.kid)
        assertEquals(3, obj.x5c?.size)
        assertEquals("c", obj.x5c?.get(2))
    }

    @Test
    fun `test covert Jwk to JSON`() {
        val json = jacksonObjectMapper().writeValueAsString(jwk)
        assertNotNull(json)
        val tree = jacksonObjectMapper().readTree(json)
        assertEquals("ES", tree["kty"].textValue())
        assertEquals("x", tree["x"].textValue())
        assertEquals("b", (tree["x5c"] as ArrayNode)[1].textValue())
    }

    @Test
    fun `test convert JSON String to RSAPublicKey`() {
        val rsaPublicKey = JwkFactory.generateRSAPublicKeyFromJwtString(rsaPublicKeyStr)
        assertNotNull(rsaPublicKey)
        assertEquals("RSA",rsaPublicKey.algorithm)
        assertNotNull(rsaPublicKey)  // lame test
        assertEquals(BigInteger(exponent.decodeBase64()), rsaPublicKey.publicExponent)
        // not so straightforward as this
        // assertEquals(BigInteger(modulus.decodeBase64()), rsaPublicKey.modulus)
    }

    @Test
    fun `test convert JSON String to ECPublicKey`() {
        val ecPublicKey = JwkFactory.generateECPublicKeyFromJwtString(ecPublicKeyStr)
        assertNotNull(ecPublicKey)
        assertNotNull(ecPublicKey)
        assertEquals("EC",ecPublicKey.algorithm)
        assertNotNull(ecPublicKey.w)  // lame test
        // not so straightforward as this
        // assertEquals(BigInteger(affineX.decodeBase64()), ecPublicKey.w.affineX)
    }

    @Test
    fun `test convert pem to JWK obj`() {
        val jwk = JWK.parseFromPEMEncodedObjects(pemPublicESKey)
        assertEquals(KeyType.EC, jwk.keyType)
    }

    @Test
    fun `test convert pem to ECPublicKey`() {
        // Step 1:   convert the .pem file into an internal jwk obj.
        val jwk = JWK.parseFromPEMEncodedObjects(pemPublicESKey)
        assertEquals(KeyType.EC, jwk.keyType)
        // Step 2:  convert the jwk object to an ecpublicKey object
        val ecPublicKey = JwkFactory.generateECPublicKeyFromJwkObj(jwk)
        assertNotNull(ecPublicKey)
        assertEquals("EC",ecPublicKey.algorithm)
        assertNotNull(ecPublicKey.w)  // lame test
    }

    @Test
    fun `test convert example FHIRAuth to obj`() {
        // this jwkset is from the RFC specification for JWKs, so I thought it would be a nice test.
        // See https://tools.ietf.org/html/rfc7517
        val fhirAuthString = """
       {"scope": "foobar",
       "jwkSet": { "keys":
        [
         {"kty":"EC",
          "crv":"P-256",
          "x":"MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
          "y":"4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM",
          "use":"enc",
          "kid":"1"},

         {"kty":"RSA",
          "n": "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",          "e":"AQAB",
          "alg":"RS256",
          "kid":"2011-04-29"}
         ]
         }
        }            
        """.trimIndent()
        val jwkSet = JwkFactory.generateFHIRAuthFromJsonString(fhirAuthString)
        assertEquals("foobar", jwkSet.scope)
        val key1 = jwkSet.jwkSet.keys[0]
        assertEquals("1", key1.keyID)
        assertEquals(KeyType.EC, key1.keyType)
    }

    @Test
    fun `test convert string FHIRAuth to ECPublicKey`() {
        val fhirAuthString = """
            {  
                "scope": "read:reports",
                "jwkSet": { "keys": [  $ecPublicKeyStr ] }
            }
        """.trimIndent()
        val fhirAuth = JwkFactory.generateFHIRAuthFromJsonString(fhirAuthString)
        val ecPublicKey = JwkFactory.generateECPublicKeyFromJwkObj(fhirAuth.jwkSet.keys[0])
        assertNotNull(ecPublicKey)
        assertEquals("EC",ecPublicKey.algorithm)
        assertNotNull(ecPublicKey.w)  // lame test
    }


}