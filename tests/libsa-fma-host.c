#include <stdint.h>
#include <stdio.h>
#include <math.h>
#include <fenv.h>
#include <unistd.h>
extern double darter_fma(double,double,double);
static uint64_t seed=123456789;
static uint64_t next(void){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
static double value(uint64_t n){union{uint64_t u;double d;}v={n};return v.d;}
static uint64_t bits(double d){union{double d;uint64_t u;}v={d};return v.u;}
int main(void){
 int modes[]={FE_TONEAREST,FE_DOWNWARD,FE_UPWARD,FE_TOWARDZERO};
 double edges[]={0.,-0.,0x1p-1074,-0x1p-1074,0x1p-1022,
  -0x1p-1022,0x0.fffffffffffffp-1022,0x1p-52,1.,-1.,
  0x1.0000000000001p0,0x1.fffffffffffffp-1,0x1p1023,
  0x1.fffffffffffffp1023,INFINITY,-INFINITY,NAN};
 for(unsigned m=0;m<4;m++){
  fesetround(modes[m]);
  for(unsigned i=0;i<sizeof edges/sizeof *edges;i++)
   for(unsigned j=0;j<sizeof edges/sizeof *edges;j++)
    for(unsigned k=0;k<sizeof edges/sizeof *edges;k++){
     double a=darter_fma(edges[i],edges[j],edges[k]);
     double b=fma(edges[i],edges[j],edges[k]);
     if(bits(a)!=bits(b)&&!(isnan(a)&&isnan(b))){
      printf("EDGE FAIL mode=%u %a %a %a got=%a want=%a\n",m,edges[i],edges[j],edges[k],a,b);return 1;
     }
    }
  for(int i=0;i<100000;i++){
   double x=value(next()),y=value(next()),z=value(next());
   double a=darter_fma(x,y,z),b=fma(x,y,z);
   if(bits(a)!=bits(b)&&!(isnan(a)&&isnan(b))){printf("FAIL mode=%u i=%d %a %a %a got=%a want=%a\n",m,i,x,y,z,a,b);return 1;}
  }
 }
 puts("FMA PASS 400000 random cases + 19652 edge cases, four rounding modes");
}
