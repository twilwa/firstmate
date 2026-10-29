#include <stdio.h>
#include <stdlib.h>
int main(){int n,R;scanf("%d %d",&n,&R);long long d[32][8];char name[32][128];int lane[32];long long tot[8]={0};
for(int i=0;i<n;i++){for(int r=0;r<R;r++){scanf("%lld",&d[i][r]);tot[r]+=d[i][r];}scanf("%s %d",name[i],&lane[i]);}
/* item 0 (pi-primary-types) pinned to lane 1 */
double best=9;unsigned long bestm=0;double tgt=0;unsigned long tm=0;
for(int i=1;i<n;i++) if(lane[i]==1) tm|=1UL<<(i-1);
int k=n-1;unsigned long N=1UL<<k;
for(unsigned long mask=0;mask<N;mask++){double w=0;for(int r=0;r<R;r++){long long a=d[0][r];for(int i=0;i<k;i++) if(mask>>i&1) a+=d[i+1][r];long long b=tot[r]-a;long long mx=a>b?a:b;double g=(double)(a>b?a-b:b-a)/mx;if(g>w)w=g; if(w>=best && mask!=tm) break;}
 if(mask==tm) tgt=w; if(w<best){best=w;bestm=mask;} if(mask==tm) ;}
printf("splits searched: %lu\ntarget split worst gap: %.6f%%\nbest split worst gap: %.6f%%\nbest equals target: %s\n",N,100*tgt,100*best,bestm==tm?"yes":"no");
if(bestm!=tm){printf("best lane1:\n  %s\n",name[0]);for(int i=0;i<k;i++) if(bestm>>i&1) printf("  %s\n",name[i+1]);}
for(int r=0;r<R;r++){long long a=d[0][r];for(int i=0;i<k;i++) if(tm>>i&1) a+=d[i+1][r];printf("run%d target lanes: %lld s / %lld s gap %.1f%%\n",r,a/1000,(tot[r]-a)/1000,100.0*(a>tot[r]-a?a-(tot[r]-a):(tot[r]-a)-a)/(a>tot[r]-a?a:tot[r]-a));}
}
