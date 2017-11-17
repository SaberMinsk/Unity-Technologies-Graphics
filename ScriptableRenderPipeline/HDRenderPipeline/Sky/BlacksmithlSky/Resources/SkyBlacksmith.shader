Shader "Hidden/HDRenderPipeline/Sky/SkyBlacksmith"
{
    SubShader
    {
        Pass
        {
            ZWrite Off
            ZTest Always
            Blend One OneMinusSrcAlpha, Zero One
            Cull Off

            HLSLPROGRAM
            #pragma target 4.5
            #pragma only_renderers d3d11 ps4 vulkan metal  // TEMP: until we go further in dev

            #pragma vertex Vert
            #pragma fragment Frag

            #pragma multi_compile _ ATMOSPHERICS_DEBUG
            #pragma multi_compile _ PERFORM_SKY_OCCLUSION_TEST

            #include "../../../../Core/ShaderLibrary/Color.hlsl"
            #include "../../../../Core/ShaderLibrary/Common.hlsl"
            #include "../../../../Core/ShaderLibrary/CommonLighting.hlsl"
            #include "../../../ShaderVariables.hlsl"

            TEXTURECUBE(_Cubemap);
            SAMPLERCUBE(sampler_Cubemap);

            float4x4 _PixelCoordToViewDirWS; // Actually just 3x3, but Unity can only set 4x4
            // x exposure, y multiplier, z rotation
            float4   _SkyParam;
            float    _SkyDepth;
            float    _DisableSkyOcclusionTest;

            #define IS_RENDERING_SKY
            #include "AtmosphericScattering_blacksmith.hlsl"

            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID, UNITY_RAW_FAR_CLIP_VALUE);
                return output;
            }

            float4 Frag(Varyings input) : SV_Target
            {
                // Points towards the camera
                float3 viewDirWS = normalize(mul(float3(input.positionCS.xy, 1.0), (float3x3)_PixelCoordToViewDirWS));
                // Reverse it to point into the scene
                float3 dir = -viewDirWS;

                // Rotate direction
                float phi = DegToRad(_SkyParam.z);
                float cosPhi, sinPhi;
                sincos(phi, sinPhi, cosPhi);
                float3 rotDirX = float3(cosPhi, 0, -sinPhi);
                float3 rotDirY = float3(sinPhi, 0, cosPhi);
                float3 rotatedDir = float3(dot(rotDirX, dir), dir.y, dot(rotDirY, dir));

                // input.positionCS is SV_Position
                PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw);

                #ifdef PERFORM_SKY_OCCLUSION_TEST
                    // Determine whether the sky is occluded by the scene geometry.
                    // Do not perform blending with the environment map if the sky is occluded.
                    float depthRaw     = max(_SkyDepth, LOAD_TEXTURE2D(_MainDepthTexture, posInput.unPositionSS).r);
                    float skyTexWeight = (depthRaw > _SkyDepth) ? 0.0 : 1.0;
                #else
                    float depthRaw     = _SkyDepth;
                    float skyTexWeight = 1.0;
                #endif

                if (_DisableSkyOcclusionTest != 0.0)
                {
                    depthRaw     = _SkyDepth;
                    skyTexWeight = 1.0;
                }

                // Since we only need the world space position, so we don't pass the view-projection matrix.
                UpdatePositionInput(depthRaw, UNITY_MATRIX_I_VP, k_identity4x4, posInput);

                float4 c1, c2, c3;
                VolundTransferScatter(GetAbsolutePositionWS(posInput.positionWS), c1, c2, c3);

                float4 coord1 = float4(c1.rgb + c3.rgb, max(0.f, 1.f - c1.a - c3.a));
                float3 coord2 = c2.rgb;

                float sunCos = dot(normalize(dir), _SunDirection);
                float miePh  = MiePhase(sunCos, _MiePhaseAnisotropy);

                float2 occlusion  = float2(1.0, 1.0); // TODO.
                float  extinction = coord1.a;
                float3 scatter    = coord1.rgb * occlusion.x + coord2 * miePh * occlusion.y;

                #ifdef ATMOSPHERICS_DEBUG
                    switch (_AtmosphericsDebugMode)
                    {
                        case ATMOSPHERICS_DBG_RAYLEIGH:           return c1;
                        case ATMOSPHERICS_DBG_MIE:                return c2 * miePh;
                        case ATMOSPHERICS_DBG_HEIGHT:             return c3;
                        case ATMOSPHERICS_DBG_SCATTERING:         return float4(scatter, 0.0);
                        case ATMOSPHERICS_DBG_OCCLUSION:          return float4(occlusion.xy, 0.0, 0.0);
                        case ATMOSPHERICS_DBG_OCCLUDEDSCATTERING: return float4(scatter, 0.0);
                    }
                #endif

                float3 skyColor = float3(0.0, 0.0, 0.0);
                // Opacity should be proportional to extinction, but this produces wrong results.
                // It appears what the algorithm computes is not actually extinction.
                float  opacity  = (1.0 - extinction);

                if (skyTexWeight == 1.0)
                {
                    skyColor  = SAMPLE_TEXTURECUBE_LOD(_Cubemap, sampler_Cubemap, rotatedDir, 0).rgb;
                    skyColor *= exp2(_SkyParam.x) * _SkyParam.y;
                    opacity   = 1.0; // Fully overwrite unoccluded scene regions.
                }

                float3 atmosphereColor = ClampToFloat16Max(skyColor * extinction + scatter);

                // Apply the atmosphere on top of the scene using premultiplied alpha blending.
                return float4(atmosphereColor, opacity);
            }

            ENDHLSL
        }

    }
    Fallback Off
}
