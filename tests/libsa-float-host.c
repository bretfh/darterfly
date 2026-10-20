#include <stdint.h>
#include <stdio.h>
#include <math.h>
#include <fenv.h>
#include <float.h>
extern float darter_nextafterf(float,float), darter_roundf(float), darter_rintf(float);
extern long darter_lroundf(float), darter_lrintf(float);
extern long long darter_llroundf(float);
extern float darter_fminf(float,float), darter_fmaxf(float,float);
extern double darter_remainder(double,double),darter_round(double),darter_rint(double);
extern long long darter_llround(double);
extern float darter_erff(float),darter_ldexpf(float,int),darter_frexpf(float,int *);
extern float darter_logf(float),darter_exp2f(float),darter_remainderf(float,float);
extern float darter_fmaf(float,float,float);
extern double darter_nan(const char *);
extern float darter_nanf(const char *);
static uint32_t seed=0x15638a2du;
static uint32_t next(void) { seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed; }
static float from(uint32_t u) { union { uint32_t u; float f; } v={.u=u};return v.f; }
static uint32_t bits(float f) { union { uint32_t u; float f; } v={.f=f};return v.u; }
static int same(float a,float b) { return (isnan(a)&&isnan(b)) || bits(a)==bits(b); }
static int check(float x,float y) {
    float a=darter_nextafterf(x,y), b=nextafterf(x,y);
    if(!same(a,b)) { printf("nextafter %08x %08x got=%08x want=%08x\n",bits(x),bits(y),bits(a),bits(b));return 0; }
    /* C99 missing-data semantics, including the NaNs quieted by Low's
       widening ABI. glibc instead propagates an original signaling NaN. */
    a=darter_fminf(x,y);b=isnan(x)?y:isnan(y)?x:fminf(x,y);
    if(!(a==0 && b==0) && !same(a,b)) { printf("min/max %08x %08x got=%08x want=%08x\n",bits(x),bits(y),bits(a),bits(b)); return 0; }
    a=darter_fmaxf(x,y);b=isnan(x)?y:isnan(y)?x:fmaxf(x,y);
    if(!(a==0 && b==0) && !same(a,b)) { printf("min/max %08x %08x got=%08x want=%08x\n",bits(x),bits(y),bits(a),bits(b)); return 0; }
    a=darter_roundf(x);b=roundf(x);
    if(!same(a,b)) { printf("round %08x got=%08x want=%08x\n",bits(x),bits(a),bits(b));return 0; }
    a=darter_rintf(x);b=rintf(x);
    if(!same(a,b)) { printf("rintf %a got=%a want=%a\n",x,a,b);return 0; }
    if(isfinite(x) && fabsf(x)<0x1p62f && darter_lroundf(x)!=lroundf(x)) return 0;
    if(isfinite(x) && fabsf(x)<0x1p62f &&
       (darter_lrintf(x)!=lrintf(x) || darter_llroundf(x)!=llroundf(x))) return 0;
    int e1=0,e2=0;
    a=darter_frexpf(x,&e1);b=frexpf(x,&e2);
    if(!same(a,b) || (isfinite(x) && e1!=e2))return 0;
    int exponent=(int)(bits(y)%601)-300;
    a=darter_ldexpf(x,exponent);b=ldexpf(x,exponent);
    if(!same(a,b))return 0;
    a=darter_remainderf(x,y);b=remainderf(x,y);
    /* An exact zero remainder has the sign of x, in every rounding mode.
       Host glibc subtraction can instead produce -0 under FE_DOWNWARD. */
    if(b==0)b=copysignf(0,x);
    if(!same(a,b)){printf("remainderf %a %a got=%a want=%a\n",x,y,a,b);return 0;}
    return 1;
}
static int reduced(uint64_t x,uint64_t y) {
    union { uint64_t u; double d; } a={.u=x},b={.u=y},got,want;
    got.d=darter_remainder(a.d,b.d);want.d=remainder(a.d,b.d);
    if(!((isnan(got.d)&&isnan(want.d)) || got.u==want.u)) {
        printf("remainder %a %a got=%a want=%a\n",a.d,b.d,got.d,want.d);return 0;
    }
    got.d=darter_round(a.d);want.d=round(a.d);
    if(!((isnan(got.d)&&isnan(want.d)) || got.u==want.u)) {
        printf("round %a got=%a want=%a\n",a.d,got.d,want.d);return 0;
    }
    got.d=darter_rint(a.d);want.d=rint(a.d);
    if(!((isnan(got.d)&&isnan(want.d)) || got.u==want.u))return 0;
    if(isfinite(a.d) && fabs(a.d)<0x1p62 && darter_llround(a.d)!=llround(a.d))return 0;
    return 1;
}
static int fused(float x,float y,float z) {
    float a=darter_fmaf(x,y,z),b=fmaf(x,y,z);
    if(!same(a,b)) {
        printf("fmaf %a %a %a got=%a want=%a\n",x,y,z,a,b); return 0;
    }
    return 1;
}
static int erf_check(float x) {
    float a=darter_erff(x),b=erff(x);
    if(isnan(a)&&isnan(b))return 1;
    int64_t gap=(int64_t)bits(a)-(int64_t)bits(b);
    if(gap<0)gap=-gap;
    if(gap<=2 && isfinite(a))return 1;
    printf("erff %a got=%a want=%a gap=%lld\n",x,a,b,(long long)gap);return 0;
}
static int elementary(float x) {
    float got[]={darter_logf(x),darter_exp2f(x)};
    float want[]={logf(x),exp2f(x)};
    for(unsigned i=0;i<2;++i) {
        if(same(got[i],want[i]))continue;
        int64_t gap=(int64_t)bits(got[i])-(int64_t)bits(want[i]);
        if(gap<0)gap=-gap;
        if(!isfinite(got[i]) || !isfinite(want[i]) || gap>2) {
            printf("elementary %u %a got=%a want=%a\n",i,x,got[i],want[i]);return 0;
        }
    }
    return 1;
}
int main(void) {
    if (!isnan(darter_nan("")) || !isnan(darter_nan("payload")) ||
        !isnan(darter_nanf("")) || !isnan(darter_nanf("123"))) return 12;
    if(bits(darter_fminf(0.0f,-0.0f))!=0x80000000u ||
       bits(darter_fminf(-0.0f,0.0f))!=0x80000000u ||
       bits(darter_fmaxf(0.0f,-0.0f))!=0 ||
       bits(darter_fmaxf(-0.0f,0.0f))!=0) return 5;
    uint64_t doubles[]={0,0x8000000000000000ULL,1,0x10000000000000ULL,
        0x3ff0000000000000ULL,0x4008000000000000ULL,0x4014000000000000ULL,
        0x3fdfffffffffffffULL,0x3fe0000000000000ULL,0x3fe0000000000001ULL,
        0xbfdfffffffffffffULL,0xbfe0000000000000ULL,0xbfe0000000000001ULL,
        0x432fffffffffffffULL,0x4330000000000000ULL,0x4330000000000001ULL,
        0x7fefffffffffffffULL,0x7ff0000000000000ULL,0x7ff8000000000000ULL};
    int modes[]={FE_TONEAREST,FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO};
    float edges[]={0,-0.0f,0x1p-149f,-0x1p-149f,0x1p-126f,-0x1p-126f,
        0x1.fffffcp-127f,1,-1,0.5f,-0.5f,2.5f,-2.5f,0x1p23f,
        0x1p24f,-0x1p24f,FLT_MAX,-FLT_MAX,INFINITY,-INFINITY,NAN};
    for(unsigned m=0;m<4;++m) {
        fesetround(modes[m]);
        for(unsigned i=0;i<sizeof doubles/sizeof *doubles;++i)
            for(unsigned j=0;j<sizeof doubles/sizeof *doubles;++j)
                if(!reduced(doubles[i],doubles[j]))return 6;
        for(unsigned i=0;i<sizeof edges/sizeof *edges;++i)
            for(unsigned j=0;j<sizeof edges/sizeof *edges;++j)
                if(!check(edges[i],edges[j]))return 1;
        for(unsigned i=0;i<sizeof edges/sizeof *edges;++i)
            for(unsigned j=0;j<sizeof edges/sizeof *edges;++j)
                for(unsigned k=0;k<sizeof edges/sizeof *edges;++k)
                    if(!fused(edges[i],edges[j],edges[k])) return 3;
        for(unsigned i=0;i<100000;++i) {
            float x=from(next()),y=from(next()),z=from(next());
            if(!check(x,y))return 2;
            if(!fused(x,y,z))return 4;
            uint64_t a=((uint64_t)next()<<32)|next(),b=((uint64_t)next()<<32)|next();
            if(!reduced(a,b))return 7;
        }
    }
    fesetround(FE_TONEAREST);
    for(unsigned i=0;i<=1000000;++i) {
        float x=-6.0f+12.0f*(float)i/1000000.0f;
        if(!erf_check(x))return 8;
    }
    for(unsigned i=0;i<100000;++i)if(!erf_check(from(next())))return 9;
    for(unsigned i=0;i<100000;++i)if(!elementary(from(next())))return 10;
    for(unsigned i=0;i<sizeof edges/sizeof *edges;++i)if(!elementary(edges[i]))return 11;
    puts("ELEMENTARY PASS logf/exp2f 100021 inputs within 2 ULP under nearest rounding");
    puts("ERFF PASS 1100001 inputs within 2 ULP under nearest rounding");
    puts("FLOAT PRIMITIVES PASS 400000 random cases, 1764 stepping/rounding edges, 37044 FMA edges, 1444 remainder edges, four rounding modes");
    return 0;
}
