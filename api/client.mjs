export class FillerApiError extends Error {
 constructor(code,status){super(code);this.name='FillerApiError';this.status=status;}
}
export function createFillerClient({baseUrl='https://uservault.fun',fetchImpl=fetch,timeoutMs=12000}={}){
 const base=new URL(baseUrl);
 if(base.protocol!=='https:'&&!(base.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(base.hostname)))throw Error('HTTPS_REQUIRED');
 if(base.username||base.password||base.search||base.hash||base.pathname!=='/')throw Error('INVALID_BASE_URL');
 if(!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>60000)throw Error('INVALID_TIMEOUT');
 const address=v=>{if(typeof v!=='string'||!/^0x[0-9a-fA-F]{40}$/.test(v))throw Error('INVALID_ADDRESS');return v;};
 const uint=v=>{if(typeof v!=='string'||!/^(0|[1-9][0-9]{0,77})$/.test(v)||BigInt(v)>=2n**256n)throw Error('INVALID_AMOUNT');return v;};
 const market=p=>{if(!p||!['BUY','SELL'].includes(p.side))throw Error('INVALID_SIDE');return {baseToken:address(p.baseToken),quote:address(p.quote),side:p.side};};
 async function request(route,options){
  const response=await fetchImpl(new URL('/api/v1/fillers'+route,base),{...options,redirect:'error',cache:'no-store',signal:AbortSignal.timeout(timeoutMs)});
  let result;try{result=await response.json();}catch{throw new FillerApiError('INVALID_JSON',response.status);}
  if(!response.ok)throw new FillerApiError(typeof result?.error==='string'?result.error:'HTTP_ERROR',response.status);
  if(result?.schema!==1||result.chainId!==4663)throw new FillerApiError('UNEXPECTED_RESPONSE',response.status);
  return result;
 }
 return Object.freeze({
  metadata:()=>request('',{method:'GET'}),
  liquidity:p=>request('/liquidity?'+new URLSearchParams(market(p)),{method:'GET'}),
  async quote(p){
   const body={...market(p),taker:address(p.taker),recipient:address(p.recipient),maxGrossInput:uint(p.maxGrossInput),minGrossInputFilled:uint(p.minGrossInputFilled),slippageBps:p.slippageBps};
   if(BigInt(body.maxGrossInput)===0n||BigInt(body.minGrossInputFilled)>BigInt(body.maxGrossInput))throw Error('INVALID_FILL_LIMIT');
   if(!Number.isInteger(body.slippageBps)||body.slippageBps<0||body.slippageBps>1000)throw Error('INVALID_SLIPPAGE');
   const result=await request('/quote',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
   if(result.status!=='SIMULATED_QUOTE'||!result.transaction||result.transaction.chainId!=='0x1237'||result.liquidityReservation!==false)throw new FillerApiError('UNEXPECTED_QUOTE',200);
   return result;
  }
 });
}
