/* Real upstream rendering dependencies in a native Darterfly world. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <malloc.h>
#include <stdint.h>
#include <sys/time.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include <fontconfig/fontconfig.h>
#include <png.h>
#include <jpeglib.h>
#include <webp/encode.h>
#include <webp/decode.h>
#include <libxml/parser.h>
#include <gcrypt.h>
#include <libtasn1.h>
#include <xkbcommon/xkbcommon.h>

static void check(const char *name, int ok) {
    printf("RENDER %s %s\n", ok ? "PASS" : "FAIL", name);
    fflush(stdout);
    if (!ok) exit(1);
}
static void fonts(void) {
    const char *path = "/Users/darterfly/DejaVuSans.ttf";
    FT_Library lib; FT_Face face;
    check("freetype-open", !FT_Init_FreeType(&lib) &&
          !FT_New_Face(lib, path, 0, &face) && !FT_Set_Pixel_Sizes(face, 0, 32));
    hb_font_t *font = hb_ft_font_create_referenced(face);
    hb_buffer_t *buffer = hb_buffer_create();
    hb_buffer_add_utf8(buffer, "office", -1, 0, -1);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font, buffer, NULL, 0);
    unsigned count;
    hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);
    check("harfbuzz-ligature", count > 0 && count < 6);
    unsigned pixels = 0; int advance = 0;
    for (unsigned i = 0; i < count; ++i) {
        check("glyph-rasterize", glyphs[i].codepoint &&
              !FT_Load_Glyph(face, glyphs[i].codepoint, FT_LOAD_RENDER));
        FT_Bitmap *bm = &face->glyph->bitmap;
        check("glyph-gray-bitmap", bm->pixel_mode == FT_PIXEL_MODE_GRAY && bm->pitch > 0);
        for (unsigned y=0; y<bm->rows; ++y)
            for (unsigned x=0; x<bm->width; ++x)
                pixels += bm->buffer[y*bm->pitch+x] != 0;
        advance += positions[i].x_advance;
    }
    printf("RENDER TEXT glyphs=%u covered-pixels=%u advance=%d\n", count, pixels, advance);
    check("text-pixels", pixels > 300 && advance > 2000);
    hb_buffer_destroy(buffer); hb_font_destroy(font);
    FT_Done_Face(face); FT_Done_FreeType(lib);
    FcConfig *config = FcConfigCreate();
    check("fontconfig-register", config && FcConfigAppFontAddFile(config, (const FcChar8 *)path));
    FcPattern *pattern = FcNameParse((const FcChar8 *)"DejaVu Sans");
    FcConfigSubstitute(config, pattern, FcMatchPattern); FcDefaultSubstitute(pattern);
    FcResult result; FcPattern *match = FcFontMatch(config, pattern, &result);
    FcChar8 *file = NULL;
    check("fontconfig-match", match && FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch &&
          !strcmp((const char *)file, path));
    FcPatternDestroy(match); FcPatternDestroy(pattern); FcConfigDestroy(config);
}
static void images(void) {
    unsigned char rgb[8*8*3];
    for (int i=0; i<64; ++i) { rgb[3*i]=32; rgb[3*i+1]=128; rgb[3*i+2]=224; }
    png_image im = {0}; im.version=PNG_IMAGE_VERSION; im.width=im.height=8; im.format=PNG_FORMAT_RGB;
    png_alloc_size_t size=0;
    check("png-size", png_image_write_to_memory(&im, NULL, &size, 0, rgb, 0, NULL));
    void *bytes=malloc(size);
    check("png-encode", bytes && png_image_write_to_memory(&im, bytes, &size, 0, rgb, 0, NULL));
    png_image decoded={0}; decoded.version=PNG_IMAGE_VERSION;
    unsigned char output[sizeof rgb];
    check("png-header", png_image_begin_read_from_memory(&decoded, bytes, size) && decoded.width==8 && decoded.height==8);
    decoded.format=PNG_FORMAT_RGB;
    check("png-pixels", png_image_finish_read(&decoded, NULL, output, 0, NULL) && !memcmp(rgb, output, sizeof rgb));
    png_image_free(&decoded); free(bytes);
    uint8_t *webp=NULL; size_t n=WebPEncodeLosslessRGB(rgb,8,8,24,&webp);
    int width=0,height=0; uint8_t *pixels=WebPDecodeRGB(webp,n,&width,&height);
    check("webp-pixels", n && pixels && width==8 && height==8 && !memcmp(rgb,pixels,sizeof rgb));
    WebPFree(pixels); WebPFree(webp);
    struct jpeg_compress_struct c; struct jpeg_error_mgr ce;
    c.err=jpeg_std_error(&ce); jpeg_create_compress(&c);
    unsigned char *jpg=NULL; unsigned long length=0;
    jpeg_mem_dest(&c,&jpg,&length); c.image_width=c.image_height=8;
    c.input_components=3; c.in_color_space=JCS_RGB; jpeg_set_defaults(&c);
    jpeg_set_quality(&c,90,TRUE); jpeg_start_compress(&c,TRUE);
    while(c.next_scanline<8) { JSAMPROW row=rgb+c.next_scanline*24; jpeg_write_scanlines(&c,&row,1); }
    jpeg_finish_compress(&c); jpeg_destroy_compress(&c);
    struct jpeg_decompress_struct d; struct jpeg_error_mgr de;
    d.err=jpeg_std_error(&de); jpeg_create_decompress(&d); jpeg_mem_src(&d,jpg,length);
    check("jpeg-header", jpeg_read_header(&d,TRUE)==JPEG_HEADER_OK);
    d.out_color_space=JCS_RGB; jpeg_start_decompress(&d);
    check("jpeg-dimensions", d.output_width==8 && d.output_height==8 && d.output_components==3);
    while(d.output_scanline<8) { JSAMPROW row=output+d.output_scanline*24; jpeg_read_scanlines(&d,&row,1); }
    jpeg_finish_decompress(&d); jpeg_destroy_decompress(&d); free(jpg);
    int ok=1; for(unsigned i=0;i<sizeof rgb;++i) if(abs((int)rgb[i]-output[i])>3) ok=0;
    check("jpeg-pixels",ok);
}
static void crypto(void) {
    check("gcrypt-version",gcry_check_version("1.7.0")!=NULL);
    check("gcrypt-secure-memory",!gcry_control(GCRYCTL_INIT_SECMEM,16384,NULL));
    check("gcrypt-initialize",!gcry_control(GCRYCTL_INITIALIZATION_FINISHED,NULL));
    static const unsigned char sha[32]={0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
    unsigned char digest[32]; gcry_md_hash_buffer(GCRY_MD_SHA256,digest,"abc",3);
    check("sha256-known-answer",!memcmp(sha,digest,32));
    unsigned char key[16]={0}, plain[16]={0}, encrypted[16];
    static const unsigned char aes[16]={0x66,0xe9,0x4b,0xd4,0xef,0x8a,0x2c,0x3b,0x88,0x4c,0xfa,0x59,0xca,0x34,0x2b,0x2e};
    gcry_cipher_hd_t handle;
    check("aes-open",!gcry_cipher_open(&handle,GCRY_CIPHER_AES128,GCRY_CIPHER_MODE_ECB,0));
    check("aes-key",!gcry_cipher_setkey(handle,key,16));
    check("aes-known-answer",!gcry_cipher_encrypt(handle,encrypted,16,plain,16)&&!memcmp(aes,encrypted,16));
    gcry_cipher_close(handle);
    unsigned char a[32],b[32]; gcry_randomize(a,32,GCRY_STRONG_RANDOM); gcry_randomize(b,32,GCRY_STRONG_RANDOM);
    check("gcrypt-random",memcmp(a,b,32)!=0);
    unsigned char der[16]; int length=0;
    asn1_length_der(128,der,&length);
    check("asn1-length",length==2 && der[0]==0x81 && der[1]==0x80);
}
static void keyboard(void) {
    const char *map="xkb_keymap { xkb_keycodes { minimum=8; maximum=255; <AC01>=38; }; xkb_types { type \"ONE_LEVEL\" { modifiers=None; map[None]=Level1; }; }; xkb_compatibility {}; xkb_symbols { key <AC01> { type=\"ONE_LEVEL\", [ a ] }; }; };";
    struct xkb_context *ctx=xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES);
    struct xkb_keymap *keymap=xkb_keymap_new_from_string(ctx,map,XKB_KEYMAP_FORMAT_TEXT_V1,XKB_KEYMAP_COMPILE_NO_FLAGS);
    check("xkb-keymap",keymap!=NULL);
    struct xkb_state *state=xkb_state_new(keymap);
    check("xkb-key-symbol",state && xkb_state_key_get_one_sym(state,38)==XKB_KEY_a);
    char utf8[8]={0}; check("xkb-key-text",xkb_state_key_get_utf8(state,38,utf8,sizeof utf8)==1 && !strcmp(utf8,"a"));
    xkb_state_unref(state); xkb_keymap_unref(keymap); xkb_context_unref(ctx);
}
static void allocator(void) {
    check("allocator-null-size",malloc_usable_size(NULL)==0);
    size_t sizes[]={0,1,17,4096,524288,700001};
    for(unsigned i=0;i<sizeof sizes/sizeof *sizes;++i) {
        unsigned char *p=malloc(sizes[i]);
        size_t usable=malloc_usable_size(p);
        check("allocator-capacity",p && usable>=sizes[i]);
        memset(p,0xa5,usable);
        p=realloc(p,sizes[i]+33);
        check("allocator-realloc-capacity",p && malloc_usable_size(p)>=sizes[i]+33);
        int intact=1;
        for(size_t j=0;j<sizes[i];++j) if(p[j]!=0xa5) intact=0;
        check("allocator-realloc-bytes",intact);
        free(p);
    }
    for(size_t alignment=32;alignment<=4096;alignment*=2) {
        void *p=NULL;
        check("allocator-aligned",posix_memalign(&p,alignment,517)==0 &&
              (uintptr_t)p%alignment==0 && malloc_usable_size(p)>=517);
        memset(p,0x5a,malloc_usable_size(p));
        free(p);
    }
}
int main(void) {
    struct timeval a={1,999999},b={2,0};
    check("time-comparison",timercmp(&a,&b,<)&&timercmp(&a,&b,!=)&&!timercmp(&a,&b,>=));
    check("float-math",fabsf(sinf(0.5f)-0.47942555f)<0.000001f &&
          fabsf(cosf(0.5f)-0.87758256f)<0.000001f &&
          fabsf(tanf(0.5f)-0.5463025f)<0.000001f &&
          fabsf(atanf(0.5f)-0.4636476f)<0.000001f && hypotf(3,4)==5 &&
          isfinite(hypotf(1e30f,1e30f)) && isinf(hypotf(INFINITY,NAN)));
    check("float-neighbor", nextafterf(1.0f,2.0f)==0x1.000002p0f &&
          nextafterf(1.0f,0.0f)==0x1.fffffep-1f &&
          nextafterf(0.0f,1.0f)==0x1p-149f &&
          nextafterf(-0x1p-149f,0.0f)==0.0f &&
          signbit(nextafterf(-0x1p-149f,0.0f)) &&
          nextafterf(INFINITY,0.0f)==0x1.fffffep127f &&
          isinf(nextafterf(0x1.fffffep127f,INFINITY)) &&
          nextafterf(0x1p-126f,0.0f)==0x1.fffffcp-127f &&
          isnan(nextafterf(NAN,1.0f)));
    check("float-round", roundf(2.5f)==3 && roundf(-2.5f)==-3 &&
          lroundf(-2.5f)==-3 && signbit(roundf(-0.0f)));
    check("float-render-math", fabsf(powf(4,0.5f)-2)<0.000001f &&
          fmodf(5.5f,2)==1.5f && signbit(copysignf(1,-1)) &&
          fabsf(acosf(0)-1.5707963f)<0.000001f &&
          fabsf(asinf(1)-1.5707963f)<0.000001f && log2f(8)==3 &&
          fabsf(log10f(10)-1)<0.000001f && fabsf(cbrtf(8)-2)<0.000001f &&
          lrintf(2.5f)==2 && llroundf(2.5f)==3 &&
          fmaf(0x1.000002p0f,0x1.fffffep-1f,-1.0f)==0x1.fffffcp-25f);
    allocator(); fonts(); images();
    const char *xml="<page><title>Darterfly</title></page>";
    xmlDocPtr doc=xmlReadMemory(xml,strlen(xml),"page.xml",NULL,XML_PARSE_NONET);
    check("xml-tree",doc && !xmlStrcmp(xmlDocGetRootElement(doc)->name,(const xmlChar *)"page"));
    xmlFreeDoc(doc); crypto(); keyboard();
    puts("RENDER PASS COMPLETE"); return 0;
}
