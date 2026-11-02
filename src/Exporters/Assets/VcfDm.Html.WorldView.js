    // Persistent, layered infrastructure topology with source-scoped object relationships.
    // Native IDs remain scoped to their vCenter. Clicks toggle branches; zoom respects manual closure.
    const worldSvg=document.getElementById('world-svg');
    const worldScene=document.getElementById('world-scene');
    const worldViewport=document.getElementById('world-viewport');
    const worldDetail=document.getElementById('world-detail');
    const worldSearch=document.getElementById('world-search');
    const worldMini=document.getElementById('world-minimap');
    const worldView=document.getElementById('view-world'),worldPanel=worldView.querySelector('.world-map-panel');
    const worldOrientationButton=document.getElementById('world-orientation');
    const worldVmDepth=new Map(),worldHostConfig=new Set(),worldExpanded=new Set(),worldLimits=new Map();
    const worldRevealed=new Set(),worldCollapsed=new Set(),worldOpenBranches=new Set();let worldRevealTarget=null,worldDrilldown=false;
    const worldDetailOwners=(datasets,id)=>new Set(datasets.flatMap(input=>input.filter(row=>cfgSource(row)&&get(row,id)).map(row=>cfgSource(row)+'|'+get(row,id))));
    const worldVmDetails=worldDetailOwners([vs('vDisk'),vs('vPartition'),rows(snapshot.Inventory||{},'vPartition')],'VMId');
    const worldHostDetails=worldDetailOwners([vs('vNIC'),vs('vSC_VMK'),vs('vHBA')],'HostId');
    let worldGraph={nodes:[],edges:[],width:1400,height:800},worldSelected=null,worldHovered=null;
    const worldCamera={x:32,y:32,scale:1};let worldInitialized=false,worldDrag=null,worldOrientation='horizontal',worldLastSize=null;
    const worldNodeWidth=210,worldNodeHeight=76,worldStep=250,worldGap=94;
    const worldSvgNode=(tag,attributes={},value=null)=>{const node=document.createElementNS('http://www.w3.org/2000/svg',tag);Object.entries(attributes).forEach(([key,val])=>node.setAttribute(key,String(val)));if(value!==null)node.textContent=String(value);return node;};
    const worldType=ref=>ref.type==='network'?(ref.dataset==='dvSwitches'||ref.dataset==='vSwitch'?'switch':'network'):ref.type==='resource-pool'?'pool':ref.type;
    const worldKey=ref=>'native|'+ref.key;
    const worldSourceMatch=(row,ref)=>cfgSameSource(cfgSource(row),ref.source);
    const worldData=(name,ref)=>rows(snapshot.Inventory||{},name).filter(row=>worldSourceMatch(row,ref)&&String(get(row,ref.type==='host'?'HostId':'VMId',''))===ref.id);

    const worldBuildGraph=()=>{
      const nodes=new Map(),edges=[],roots=[];let omitted=0;
      const add=(key,kind,label,row={},options={})=>{
        if(nodes.has(key))return nodes.get(key);
        const node={key,kind,label:String(label),row,children:[],layer:0,source:'',ref:null,confidence:'authoritative',...options};nodes.set(key,node);return node;
      };
      const edge=(from,to,label='contains',kind='compute',confidence='authoritative')=>{if(!from||!to||from.key===to.key)return;if(!edges.some(e=>e.from===from.key&&e.to===to.key&&e.label===label))edges.push({from:from.key,to:to.key,label,kind,confidence});};
      const child=(parent,node,label='contains',kind='compute',confidence='authoritative')=>{if(!parent.children.includes(node.key)){parent.children.push(node.key);node.parent=parent.key;node.layer=parent.layer+1;}edge(parent,node,label,kind,confidence);return node;};
      const fromRef=ref=>add(worldKey(ref),worldType(ref),ref.label,ref.row,{ref,source:ref.source});
      const group=(parent,key,label,items,makeItem,options={})=>{
        const node=child(parent,add(key,'group',label,{}, {count:items.length,groupItems:items,expandable:true,...options}),options.label||'contains',options.edgeKind||'compute');
        if(worldExpanded.has(key)){
          const limit=worldLimits.get(key)||24;items.slice(0,limit).forEach((item,i)=>child(node,makeItem(item,i),'contains',options.edgeKind||'compute'));
          if(items.length>limit){child(node,add(key+'|more','group',(items.length-limit)+' more · expand',{}, {count:items.length-limit,moreFor:key,expandable:true}));omitted+=items.length-limit;}
        }
        return node;
      };
      const instanceRows=ds('VCF_Instances').length?ds('VCF_Instances'):[{VCFInstanceId:'snapshot',VCFInstanceName:'vSphere estate'}];
      const instances=new Map(instanceRows.map((row,i)=>{const id=String(get(row,'VCFInstanceId','instance-'+i));const node=add('instance|'+id,'instance',first(row,['VCFInstanceName','SDDCManagerFqdn'],'VCF instance'),row,{instanceId:id});roots.push(node);return [id,node];}));
      const domains=new Map();
      ds('VCF_Domains').forEach((row,i)=>{const id=String(get(row,'DomainId','domain-'+i));const parent=instances.get(String(get(row,'VCFInstanceId')))||roots[0];const node=child(parent,add('domain|'+id,'domain',get(row,'DomainName','Workload domain'),row,{domainId:id}));domains.set(id,node);});
      const fallbackDomains=new Map();
      const parentForRef=ref=>{
        const domain=domains.get(String(get(ref.row,'VCF Domain Id','')));if(domain)return domain;
        if(!fallbackDomains.has(ref.source)){const owner=instances.get(String(get(ref.row,'VCF Instance Id','')))||roots[0];const node=child(owner,add('unassigned|'+ref.source,'domain',ref.source||'Unassigned vSphere inventory',{}, {source:ref.source,unassigned:true}));fallbackDomains.set(ref.source,node);}
        return fallbackDomains.get(ref.source);
      };
      const clusterByNative=new Map();
      cfgClusterRefs.forEach(ref=>{const node=child(parentForRef(ref),fromRef(ref));clusterByNative.set(ref.source+'|'+ref.id,node);});
      // Retain SDDC-only clusters, but do not guess host membership from matching names.
      ds('VCF_Clusters').forEach((row,i)=>{
        const domain=domains.get(String(get(row,'DomainId')))||roots[0];
        const matches=cfgClusterRefs.filter(ref=>get(ref.row,'VCF Domain Id')===get(row,'DomainId')&&ref.label===get(row,'ClusterName'));
        if(matches.length===1){nodes.get(worldKey(matches[0])).vcfRow=row;return;}
        child(domain,add('vcf-cluster|'+String(get(row,'ClusterId',i)),'cluster',get(row,'ClusterName','VCF cluster'),row));
      });
      const hostByNative=new Map();
      const hostBuckets=new Map(),knownHosts=new Set(cfgHostRefs.map(ref=>ref.source+'|'+ref.id));
      cfgHostRefs.forEach(ref=>{const parent=clusterByNative.get(ref.source+'|'+String(get(ref.row,'ClusterId')))||parentForRef(ref);if(!hostBuckets.has(parent.key))hostBuckets.set(parent.key,[]);hostBuckets.get(parent.key).push(ref);});
      hostBuckets.forEach((refs,key)=>{const parent=nodes.get(key),limit=worldLimits.get(key+'|hosts')||8;const visible=refs.filter((ref,i)=>i<limit||worldRevealed.has(worldKey(ref)));visible.forEach(ref=>{const node=child(parent,fromRef(ref));hostByNative.set(ref.source+'|'+ref.id,node);});if(refs.length>visible.length){child(parent,add(key+'|more-hosts','group',(refs.length-visible.length)+' more hosts',{}, {moreFor:key+'|hosts',expandable:true,count:refs.length-visible.length}));omitted+=refs.length-visible.length;}});
      const workloads=new Map();
      cfgVmRefs.forEach(ref=>{
        const hostKey=ref.source+'|'+String(get(ref.row,'HostId'));if(knownHosts.has(hostKey)&&!hostByNative.has(hostKey))return;
        const parent=hostByNative.get(ref.source+'|'+String(get(ref.row,'HostId')))||clusterByNative.get(ref.source+'|'+String(get(ref.row,'ClusterId')))||parentForRef(ref);
        if(!workloads.has(parent.key))workloads.set(parent.key,[]);workloads.get(parent.key).push(ref);
      });
      const vmNodes=[];
      const addVm=ref=>{
        const node=fromRef(ref);if(get(ref.row,'Template')===true)node.kind='template';node.lazyChildren=worldVmDetails.has(ref.source+'|'+ref.id);vmNodes.push(node);
        const depth=worldVmDepth.get(node.key)||0;
        if(depth){
          const disks=vs('vDisk').filter(row=>worldSourceMatch(row,ref)&&String(get(row,'VMId'))===ref.id);
          const diskNodes=disks.slice(0,worldLimits.get(node.key+'|disks')||24).map((row,i)=>child(node,add(node.key+'|disk|'+i,'disk',get(row,'Disk','Virtual disk'),row,{ownerRef:ref,source:ref.source}), 'has disk','storage'));
          const parts=worldData('vPartition',ref).length?worldData('vPartition',ref):vs('vPartition').filter(row=>worldSourceMatch(row,ref)&&String(get(row,'VMId'))===ref.id);
          const partKey=node.key+'|filesystems';if(depth>=2)worldExpanded.add(partKey);
          group(node,partKey,'Guest filesystems',parts,(row,i)=>{
            const part=add(partKey+'|'+i,'partition',first(row,['Disk','Path','Partition Path'],'Filesystem'),row,{ownerRef:ref,source:ref.source});
            const path=get(row,'VMDK Path');const match=diskNodes.filter(disk=>path&&get(disk.row,'FileName')===path);
            if(match.length===1)edge(match[0],part,'backs filesystem','storage');
            return part;
          },{ownerRef:ref,edgeKind:'storage'});
          if(disks.length>diskNodes.length){child(node,add(node.key+'|more-disks','group',(disks.length-diskNodes.length)+' more disks',{}, {moreFor:node.key+'|disks',expandable:true}));omitted+=disks.length-diskNodes.length;}
        }
        return node;
      };
      workloads.forEach((refs,key)=>{
        const parent=nodes.get(key);const limit=worldLimits.get(key+'|workloads')||(cfgVmRefs.length>250?4:12);
        const visible=refs.filter((ref,i)=>i<limit||worldRevealed.has(worldKey(ref)));visible.forEach(ref=>child(parent,addVm(ref),'runs'));
        if(refs.length>visible.length){child(parent,add(key+'|more-workloads','group',(refs.length-visible.length)+' more workloads',{}, {moreFor:key+'|workloads',expandable:true,count:refs.length-visible.length}));omitted+=refs.length-visible.length;}
      });
      // Group service appliances rather than duplicating them as anonymous topology blobs.
      domains.forEach(domain=>{
        const services=[];const seen=new Set();
        for(const [dataset,type,labels] of [['VCF_vCenters','vCenter',['VCenterFqdn','Fqdn']],['VCF_SDDCManagers','SDDC Manager',['SDDCManagerFqdn','Fqdn']],['VCF_NSXClusters','NSX',['VipFqdn','Name']],['VCF_ManagementComponents','Management service',['ComponentFqdn','ComponentName','Name']]]){
          ds(dataset).filter(row=>String(first(row,['DomainId','ManagementDomainId'],''))===domain.domainId).forEach(row=>{const label=String(first(row,labels,type));if(seen.has(label.toLowerCase()))return;seen.add(label.toLowerCase());services.push({type,label,row});});
        }
        if(services.length)group(domain,domain.key+'|services','Management services',services,(item,i)=>add(domain.key+'|service|'+i,'component',item.label,item.row,{subtype:item.type}),{edgeKind:'services'});
      });
      hostByNative.forEach(host=>{
        if(!worldHostConfig.has(host.key))return;
        const records=[];for(const dataset of ['vNIC','vSC_VMK','vHBA'])for(const row of vs(dataset).filter(row=>worldSourceMatch(row,host.ref)&&String(get(row,'HostId'))===host.ref.id))records.push({dataset,row});
        const key=host.key+'|interfaces';
        group(host,key,'Host adapters',records,(item,i)=>add(key+'|'+i,item.dataset==='vHBA'?'hba':'interface',get(item.row,'Device','Adapter'),item.row,{ownerRef:host.ref,source:host.source,subtype:item.dataset}),{edgeKind:'network',ownerRef:host.ref});
      });
      const shared=[];
      [...cfgDatastoreRefs,...cfgNetworkRefs,...cfgResourceRefs].forEach(ref=>{const node=fromRef(ref);node.shared=true;node.ownerKey=parentForRef(ref).key;shared.push(node);});
      for(const vm of vmNodes){
        const ref=vm.ref;
        cfgRefsFromIds('datastore',ref.source,get(ref.row,'DatastoreIds')).forEach(store=>edge(vm,fromRef(store),'stored on','storage'));
        const pool=cfgExactRef('resource-pool',ref.source,get(ref.row,'ResourcePoolId'));if(pool)edge(vm,fromRef(pool),'allocated to','compute');
        vs('vNetwork').filter(row=>worldSourceMatch(row,ref)&&String(get(row,'VMId'))===ref.id).forEach(nic=>{
          const networkId=get(nic,'NetworkId');let matches=networkId?cfgNetworkRefs.filter(net=>net.source===ref.source&&net.id===String(networkId)):[];let confidence='authoritative';
          if(!networkId){matches=cfgNetworkRefs.filter(net=>net.source===ref.source&&net.dataset==='vPort'&&net.label===get(nic,'Network')&&get(net.row,'HostId')===get(ref.row,'HostId'));confidence='correlated';}
          if(matches.length===1)edge(vm,fromRef(matches[0]),'connected to','network',confidence);
        });
      }
      cfgNetworkRefs.filter(ref=>ref.dataset==='dvPorts').forEach(ref=>{const parent=cfgExactRef('network',ref.source,get(ref.row,'VDSwitchId'));if(parent){const owner=fromRef(parent),port=fromRef(ref);port.ownerKey=owner.key;edge(owner,port,'presents','network');}});
      cfgNetworkRefs.filter(ref=>ref.dataset==='vSwitch'||ref.dataset==='vPort').forEach(ref=>{const host=hostByNative.get(ref.source+'|'+String(get(ref.row,'HostId')));if(host)edge(host,fromRef(ref),'presents','network');});
      for(const node of nodes.values())if(node.kind==='disk'&&node.ownerRef){const store=cfgExactRef('datastore',node.source,get(node.row,'DatastoreId'));if(store)edge(node,fromRef(store),'backed by','storage');}
      // Collapse only descendants; shared resources follow their native domain/switch owner.
      const owned=new Map();for(const node of nodes.values())if(node.ownerKey){if(!owned.has(node.ownerKey))owned.set(node.ownerKey,[]);owned.get(node.ownerKey).push(node.key);}
      for(const node of shared){const owner=nodes.get(node.ownerKey);if(owner&&!edges.some(item=>item.from===owner.key&&item.to===node.key))edge(owner,node,'includes resource',node.kind==='datastore'?'storage':node.kind==='pool'?'compute':'network');}
      for(const node of nodes.values()){
        node.canExpand=!!(node.children.length||owned.get(node.key)?.length||node.lazyChildren||node.kind==='host'&&worldHostDetails.has(node.source+'|'+node.ref?.id)||node.kind==='group'&&node.count>0||node.moreFor);
        if(worldDrilldown&&node.canExpand&&!worldOpenBranches.has(node.key))worldCollapsed.add(node.key);
      }
      if(worldRevealTarget){let current=nodes.get(worldRevealTarget);const seen=new Set();while(current&&!seen.has(current.key)){seen.add(current.key);const parent=current.parent||current.ownerKey;if(!parent)break;worldCollapsed.delete(parent);worldOpenBranches.add(parent);current=nodes.get(parent);}worldRevealTarget=null;}
      for(const node of nodes.values())node.branchExpanded=node.canExpand&&!worldCollapsed.has(node.key)&&!!(node.children.length||owned.get(node.key)?.length);
      const hidden=new Map();
      const isHidden=node=>{if(hidden.has(node.key))return hidden.get(node.key);const parent=nodes.get(node.parent||node.ownerKey);const value=!!parent&&(worldCollapsed.has(parent.key)||isHidden(parent));hidden.set(node.key,value);return value;};
      const hiddenKeys=[...nodes.values()].filter(isHidden).map(node=>node.key);hiddenKeys.forEach(key=>nodes.delete(key));
      for(const node of nodes.values())node.children=node.children.filter(key=>nodes.has(key));
      const visibleEdges=edges.filter(item=>nodes.has(item.from)&&nodes.has(item.to));
      // Tree layout preserves several generations at once; branches grow in place.
      const vertical=worldOrientation==='vertical',breadthGap=vertical?worldNodeWidth+24:worldGap,layerStep=vertical?160:worldStep;
      const breadth=node=>vertical?node.x:node.y;
      const position=(node,flow,cross)=>{node.x=vertical?cross:flow;node.y=vertical?flow:cross;};
      const measure=node=>{node.span=Math.max(breadthGap,node.children.reduce((sum,key)=>sum+measure(nodes.get(key)),0));return node.span;};
      const place=(node,start)=>{position(node,36+node.layer*layerStep,start+node.span/2-(vertical?worldNodeWidth:worldNodeHeight)/2);let cursor=start;node.children.forEach(key=>{const next=nodes.get(key);next.layer=node.layer+1;place(next,cursor);cursor+=next.span;});};
      let cursor=72;roots.forEach(node=>{measure(node);place(node,cursor);cursor+=node.span+breadthGap;});
      const deepest=Math.max(4,...[...nodes.values()].filter(node=>!node.shared).map(node=>node.layer));
      const sharedColumns=new Map();
      shared.filter(node=>nodes.has(node.key)).forEach(node=>{node.layer=deepest+(node.kind==='network'?2:1);const related=visibleEdges.filter(e=>e.to===node.key||e.from===node.key).map(e=>nodes.get(e.to===node.key?e.from:e.to)).filter(other=>other&&!other.shared);node.desiredBreadth=related.length?related.reduce((sum,other)=>sum+breadth(other),0)/related.length:cursor/2;if(!sharedColumns.has(node.layer))sharedColumns.set(node.layer,[]);sharedColumns.get(node.layer).push(node);});
      sharedColumns.forEach(column=>{let bottom=72;column.sort((a,b)=>a.desiredBreadth-b.desiredBreadth||a.label.localeCompare(b.label)).forEach(node=>{position(node,36+node.layer*layerStep,Math.max(bottom,node.desiredBreadth));bottom=breadth(node)+breadthGap;});});
      return {nodes:[...nodes.values()],edges:visibleEdges,width:Math.max(worldNodeWidth+72,...[...nodes.values()].map(node=>node.x+worldNodeWidth+48)),height:Math.max(worldNodeHeight+110,...[...nodes.values()].map(node=>node.y+worldNodeHeight+70)),omitted,hidden:hiddenKeys.length};
    };

    // Distinct hardware and service glyphs share the application's icon vocabulary.
    const worldColors={instance:'#5db9f5',domain:'#8bafff',cluster:'#c291ed',host:'#f4b75d',vm:'#70ce96',template:'#b5d36e',datastore:'#a4b7c8',network:'#7ebee8',switch:'#5fc9c2',pool:'#adc87e',group:'#54c5b4',disk:'#dab673',partition:'#cda4e9',interface:'#6fc6db',component:'#a4b4d4'};
    const worldIcon=kind=>{
      const group=worldSvgNode('g',{'class':'world-icon',transform:'translate(13 15)',fill:'none',stroke:worldColors[kind]||'#9db8ca','stroke-width':2,'stroke-linejoin':'round','stroke-linecap':'round'});
      const shape=(tag,attrs)=>group.append(worldSvgNode(tag,attrs));
      if(kind==='host'){shape('rect',{x:2,y:1,width:34,height:44,rx:4});[10,23,36].forEach(y=>{shape('path',{d:'M8 '+y+'h16'});shape('circle',{cx:30,cy:y,r:1,fill:worldColors.host});});}
      else if(kind==='cluster'){[[0,2],[20,2],[10,27]].forEach(([x,y])=>shape('rect',{x,y,width:16,height:14,rx:2}));shape('path',{d:'M8 17v6h20v-6M18 23v4'});}
      else if(kind==='datastore'){shape('path',{d:'M2 9v28c0 9 34 9 34 0V9M2 23c0 9 34 9 34 0'});shape('ellipse',{cx:19,cy:9,rx:17,ry:7});}
      else if(kind==='switch'){shape('rect',{x:0,y:13,width:38,height:24,rx:4});[7,15,23,31].forEach(x=>shape('rect',{x:x-2,y:23,width:4,height:6,rx:1}));shape('path',{d:'M9 7h20m-4-4 4 4-4 4'});}
      else if(kind==='network'||kind==='interface'){shape('path',{d:'M19 7v15M4 31v-9h30v9M19 22v9'});[[13,0],[0,32],[13,32],[26,32]].forEach(([x,y])=>shape('rect',{x,y,width:12,height:10,rx:2}));}
      else if(kind==='disk'||kind==='partition'||kind==='hba'){shape('rect',{x:1,y:9,width:36,height:29,rx:4});shape('path',{d:'M2 29h34M7 34h9'});shape('circle',{cx:29,cy:34,r:1});if(kind==='partition')shape('path',{d:'M8 16h8v6H8zM22 16h7v6h-7z'});}
      else if(kind==='group'||kind==='pool'){[[2,3],[7,10],[12,17]].forEach(([x,y])=>shape('rect',{x,y,width:25,height:25,rx:4}));}
      else if(kind==='instance'||kind==='domain'){shape('path',{d:'M19 0 37 10v24L19 45 1 34V10Z'});shape('path',{d:'M9 15h20v15H9zM14 20h10m-10 5h10'});}
      else if(kind==='component'){shape('rect',{x:2,y:4,width:34,height:37,rx:5});shape('path',{d:'M9 13h20M9 22h20M9 31h12'});}
      else{shape('rect',{x:0,y:4,width:38,height:28,rx:3});shape('path',{d:'M13 41h12M19 32v9M5 10h28'});if(kind==='template')shape('path',{d:'M26 20h16v21H26z'});}
      return group;
    };
    const worldShort=(value,max=24)=>String(value).length>max?String(value).slice(0,max-1)+'…':String(value);
    const worldKindLabel=node=>node.subtype||({instance:'VCF instance',domain:'Workload domain',host:'ESXi host',vm:'Virtual machine',template:'VM template',disk:'Virtual disk',partition:'Guest filesystem',group:'Expandable group',pool:'Resource pool',switch:'Virtual switch',network:'Port group',interface:'Host adapter'}[node.kind]||node.kind);
    const worldStatus=node=>first(node.row,['PowerState','ConnectionState','Status','OverallStatus','LifecycleState','IsolationStatus','CollectionStatus'],'');
    const worldFactPairs=node=>{
      const row=node.row,source=node.source;const facts=[];
      const add=(label,value,unit='')=>{if(value!==null&&value!==undefined&&value!=='')facts.push([label,(typeof value==='boolean'?(value?'Yes':'No'):Array.isArray(value)?value.join(', '):String(value))+unit]);};
      const take=(label,fields,unit='')=>add(label,first(row,fields),unit);
      if(node.kind==='vm'||node.kind==='template'){
        take('Power',['PowerState']);take('CPU',['CpuCount'],' vCPU');take('Memory',['MemoryGiB'],' GiB');take('Guest IP',['PrimaryIpAddress']);take('Host',['HostName']);take('Guest OS',['GuestTools','GuestConfigured']);take('Virtual disks',['DiskCount']);
        const tools=vs('vTools').find(item=>cfgSource(item)===source&&get(item,'VMId')===get(row,'VMId'));add('VMware Tools',tools&&first(tools,['ToolsRunningStatus','ToolsStatus']));
      }else if(node.kind==='host'){
        take('ESXi',['ESXiVersion']);take('Build',['Build']);take('Connection',['ConnectionState']);take('Model',['Model']);take('CPU cores',['CpuCores']);take('Memory',['MemoryGiB'],' GiB');take('Maintenance',['MaintenanceMode']);
        const detail=rows(snapshot.Inventory||{},'vHost').find(item=>cfgSource(item)===source&&get(item,'HostId')===get(row,'HostId'));add('Memory usage',detail&&get(detail,'MemoryUsagePct'),'%');
      }else if(node.kind==='cluster'){
        take('Hosts',['HostCount']);take('HA',['DASEnabled']);take('DRS',['DRSEnabled']);take('DRS mode',['DRSBehavior']);take('Memory',['TotalMemoryGiB'],' GiB');add('vSAN',first(node.vcfRow||row,['VsanEnabled']));take('CPU capacity',['TotalCpuMHz'],' MHz');
      }else if(node.kind==='datastore'){
        take('Type',['Type']);take('Accessible',['Accessible']);take('Capacity',['CapacityGiB'],' GiB');take('Free',['FreeGiB'],' GiB');if(get(row,'CapacityGiB')>0)add('Free capacity',(Number(get(row,'FreeGiB',0))/Number(get(row,'CapacityGiB'))*100).toFixed(1),'%');take('VMs',['VmCount']);take('Hosts',['HostCount']);
      }else if(node.kind==='network'||node.kind==='switch'){
        take('Switch',['VDSwitch','Vswitch']);take('VLAN',['VlanConfiguration','VlanId']);take('MTU',['Mtu']);take('Ports',['NumPorts','Ports']);take('Binding',['PortBinding']);take('Version',['Version']);take('Vendor',['Vendor']);
      }else if(node.kind==='disk'){
        take('Capacity',['CapacityGiB'],' GiB');take('Thin',['ThinProvisioned']);take('Disk mode',['DiskMode']);take('Controller',['ControllerKey']);take('Unit',['UnitNumber']);take('VMDK',['FileName']);
      }else if(node.kind==='partition'){
        take('Capacity',['CapacityMB','CapacityGiB'],get(row,'CapacityMB')!==null?' MiB':' GiB');take('Free',['FreeMB','FreeGiB'],get(row,'FreeMB')!==null?' MiB':' GiB');take('Free percent',['FreePct'],'%');take('VMDK',['VMDK']);take('Mapping',['Mapping Available']);take('Guest family',['OS Family']);
      }else if(node.kind==='interface'){
        take('IP',['IpAddress']);take('Subnet',['SubnetMask']);take('MTU',['Mtu']);take('MAC',['Mac','MacAddress']);take('Driver',['Driver']);take('Link speed',['LinkSpeedMb'],' Mb/s');take('Port group',['Portgroup','DvPortgroupKey']);
      }else if(node.kind==='hba'){
        take('Device',['Device']);take('Model',['Model']);take('Driver',['Driver']);take('Status',['Status']);take('PCI',['Pci']);take('WWNN',['WWNN']);take('WWPN',['WWPN']);
      }else if(node.kind==='group'){
        add('Objects',node.count);add('State',worldExpanded.has(node.key)?'Expanded':'Grouped');add('Action',node.moreFor?'Activate to show more':'Double-click to expand or collapse');
      }else{
        for(const [label,fields] of [['State',['Status','IsolationStatus','LifecycleState']],['Version',['Version','CurrentVCFRelease','SystemRelease']],['Type',['DomainType','ComponentType']],['Address',['ComponentFqdn','VCenterFqdn','SDDCManagerFqdn','VipFqdn']],['Hosts',['HostCount']],['Clusters',['ClusterCount']],['CPU limit',['CpuLimitMHz']],['Memory limit',['MemoryLimitMiB']]])take(label,fields);
      }
      if(!facts.length)add('Related objects',worldGraph.edges.filter(edge=>edge.from===node.key||edge.to===node.key).length);
      if(source&&facts.length<8)add('vCenter',source);return facts.slice(0,8);
    };
    const worldShowDetail=(node,pin=false)=>{
      if(pin)worldSelected=node.key;worldDetail.textContent='';
      const heading=make('div','inspector-heading');heading.append(make('h3','',node.label),make('span','type-badge',worldKindLabel(node)));worldDetail.append(heading);
      const facts=make('dl','world-attributes');worldFactPairs(node).forEach(([key,value])=>{facts.append(make('dt','',key),make('dd','',value));});worldDetail.append(facts);
      if(node.confidence==='correlated')worldDetail.append(cfgRelationNotice('correlated','this relationship'));
      const actions=make('div','action-row');
      if(node.ref){const button=make('button','button primary','Open full configuration');button.type='button';button.addEventListener('click',()=>{cfgSelectRef(node.ref);document.querySelector('nav [data-view="virtual"]').click();});actions.append(button);}
      else if(node.ownerRef){const button=make('button','button','Open owner configuration');button.type='button';button.addEventListener('click',()=>{cfgSelectRef(node.ownerRef);document.querySelector('nav [data-view="virtual"]').click();});actions.append(button);}
      if(node.canExpand){const button=make('button','button',node.moreFor?'Show more objects':node.branchExpanded?'Collapse children':'Expand children');button.type='button';button.addEventListener('click',()=>worldExpand(node));actions.append(button);}
      if(actions.childElementCount)worldDetail.append(actions);
      worldApplyHighlight();
    };
    const worldDefaultDetail=()=>{worldDetail.textContent='';worldDetail.append(make('h3','','Object inspector'),make('p','','Hover or select an object to see its key attributes and configuration values.'));const counts=make('div','world-inspector-counts',cfgVmRefs.length+' VMs · '+cfgHostRefs.length+' hosts · '+cfgDatastoreRefs.length+' datastores');worldDetail.append(counts);};
    const worldApplyHighlight=()=>{
      const query=worldSearch.value.trim().toLowerCase(),focus=worldHovered||worldSelected;
      const active=new Set();if(focus){active.add(focus);let current=worldGraph.nodes.find(node=>node.key===focus);while(current?.parent){active.add(current.parent);current=worldGraph.nodes.find(node=>node.key===current.parent);}worldGraph.edges.filter(edge=>edge.from===focus||edge.to===focus).forEach(edge=>{active.add(edge.from);active.add(edge.to);});}
      let matches=0;
      worldScene.querySelectorAll('.world-node').forEach(element=>{const node=worldGraph.nodes.find(item=>item.key===element.getAttribute('data-key'));const match=!!query&&[node.label,worldKindLabel(node),node.source,...Object.values(node.row).map(text)].join(' ').toLowerCase().includes(query);if(match)matches++;element.classList.toggle('search-match',match);element.classList.toggle('selected',node.key===worldSelected);element.classList.toggle('active',node.key===focus);element.classList.toggle('faded',(query&&!match)||(!query&&focus&&!active.has(node.key)));});
      worldScene.querySelectorAll('.world-edge').forEach(element=>{const from=element.getAttribute('data-from'),to=element.getAttribute('data-to');element.classList.toggle('active',!!focus&&(from===focus||to===focus));element.classList.toggle('faded',!!focus&&!active.has(from)&&!active.has(to));});
      document.getElementById('world-search-count').textContent=query?matches+' matching objects':'';
    };
    const worldCameraSize=()=>{const rect=worldSvg.getBoundingClientRect();return {width:rect.width||1200,height:rect.height||780,left:rect.left||0,top:rect.top||0};};
    const worldApplyCamera=()=>{
      worldScene.setAttribute('transform','translate('+worldCamera.x+' '+worldCamera.y+') scale('+worldCamera.scale+')');
      worldSvg.setAttribute('data-detail',worldCamera.scale>=1.05?'detailed':worldCamera.scale>=.52?'normal':'overview');
      document.getElementById('world-scale').textContent=Math.round(worldCamera.scale*100)+'%';
      worldRenderMini();
    };
    const worldFit=()=>{
      const size=worldCameraSize();worldCamera.scale=Math.min(1.15,Math.max(.12,Math.min((size.width-60)/worldGraph.width,(size.height-180)/worldGraph.height)));
      worldCamera.x=(size.width-worldGraph.width*worldCamera.scale)/2;worldCamera.y=28;worldApplyCamera();worldInitialized=worldView.classList.contains('active');worldLastSize=worldInitialized?size:null;
    };
    const worldRenderMini=()=>{
      worldMini.textContent='';worldMini.setAttribute('viewBox','0 0 '+worldGraph.width+' '+worldGraph.height);
      worldMini.append(worldSvgNode('rect',{x:0,y:0,width:worldGraph.width,height:worldGraph.height,fill:'#10283c'}));
      worldGraph.nodes.forEach(node=>worldMini.append(worldSvgNode('rect',{x:node.x,y:node.y,width:worldNodeWidth,height:worldNodeHeight,rx:8,fill:worldColors[node.kind]||'#9db8ca',opacity:node.key===worldSelected?1:.62})));
      const size=worldCameraSize();worldMini.append(worldSvgNode('rect',{x:-worldCamera.x/worldCamera.scale,y:-worldCamera.y/worldCamera.scale,width:size.width/worldCamera.scale,height:size.height/worldCamera.scale,fill:'#ffffff', 'fill-opacity':.06,stroke:'#fff','stroke-width':10,'class':'minimap-camera'}));
    };
    const worldPreserveRender=anchor=>{
      const old=anchor&&worldGraph.nodes.find(node=>node.key===anchor);const screen=old?{x:old.x*worldCamera.scale+worldCamera.x,y:old.y*worldCamera.scale+worldCamera.y}:null;
      worldRender();const current=anchor&&worldGraph.nodes.find(node=>node.key===anchor);if(screen&&current){worldCamera.x=screen.x-current.x*worldCamera.scale;worldCamera.y=screen.y-current.y*worldCamera.scale;worldApplyCamera();}
    };
    const worldExpand=node=>{
      if(node.moreFor){const restoreFocus=worldScene.contains(document.activeElement);worldLimits.set(node.moreFor,(worldLimits.get(node.moreFor)||(node.moreFor.endsWith('|hosts')?8:node.moreFor.endsWith('|workloads')?(cfgVmRefs.length>250?4:12):24))+24);worldPreserveRender(node.parent);if(restoreFocus)[...worldScene.querySelectorAll('.world-node')].find(element=>element.dataset.key===node.parent)?.focus({preventScroll:true});return;}
      if(!node.canExpand)return;
      const restoreFocus=worldScene.contains(document.activeElement);
      if(node.branchExpanded){worldCollapsed.add(node.key);worldOpenBranches.delete(node.key);}
      else{
        worldCollapsed.delete(node.key);worldOpenBranches.add(node.key);
        if(node.kind==='group')worldExpanded.add(node.key);
        if((node.kind==='vm'||node.kind==='template')&&!worldVmDepth.get(node.key))worldVmDepth.set(node.key,2);
        if(node.kind==='host'&&!worldHostConfig.has(node.key)){worldHostConfig.add(node.key);worldExpanded.add(node.key+'|interfaces');}
      }
      worldSelected=node.key;worldHovered=null;
      worldPreserveRender(node.key);
      if(restoreFocus)[...worldScene.querySelectorAll('.world-node')].find(element=>element.dataset.key===node.key)?.focus({preventScroll:true});
    };
    const worldRender=()=>{
      worldGraph=worldBuildGraph();worldScene.textContent='';
      const layers=new Map();worldGraph.nodes.forEach(node=>{if(!layers.has(node.layer))layers.set(node.layer,new Set());layers.get(node.layer).add(worldKindLabel(node));});
      layers.forEach((labels,layer)=>worldScene.append(worldSvgNode('text',{x:worldOrientation==='vertical'?20:36+layer*worldStep,y:worldOrientation==='vertical'?22+layer*160:32,'class':'world-layer-label'},[...labels].slice(0,3).join(' / '))));
      worldGraph.edges.forEach(edge=>{
        const from=worldGraph.nodes.find(node=>node.key===edge.from),to=worldGraph.nodes.find(node=>node.key===edge.to);if(!from||!to)return;
        const vertical=worldOrientation==='vertical';
        const x1=from.x+(vertical?worldNodeWidth/2:worldNodeWidth),y1=from.y+(vertical?worldNodeHeight:worldNodeHeight/2),x2=to.x+(vertical?worldNodeWidth/2:0),y2=to.y+(vertical?0:worldNodeHeight/2);
        const curve=vertical?'M'+x1+' '+y1+'C'+x1+' '+(y1+50)+' '+x2+' '+(y2-50)+' '+x2+' '+y2:'M'+x1+' '+y1+'C'+(x1+60)+' '+y1+' '+(x2-60)+' '+y2+' '+x2+' '+y2;
        const path=worldSvgNode('path',{d:curve,'class':'world-edge '+edge.kind+(edge.confidence==='correlated'?' correlated':''),'data-from':edge.from,'data-to':edge.to,'data-kind':edge.kind});path.append(worldSvgNode('title',{},from.label+' '+edge.label+' '+to.label));worldScene.append(path);
      });
      worldGraph.nodes.forEach(node=>{
        const group=worldSvgNode('g',{'class':'world-node '+node.kind,transform:'translate('+node.x+' '+node.y+')','data-key':node.key,'data-kind':node.kind,role:'button',tabindex:0,'aria-label':worldKindLabel(node)+' '+node.label+(node.canExpand?node.moreFor?'. Show more objects.':node.branchExpanded?'. Collapse children.':'. Expand children.':'')});
        if(node.canExpand&&!node.moreFor)group.setAttribute('aria-expanded',String(node.branchExpanded));
        group.append(worldSvgNode('title',{},node.label+'\n'+worldFactPairs(node).map(pair=>pair.join(': ')).join('\n')));
        group.append(worldSvgNode('rect',{x:0,y:0,width:worldNodeWidth,height:worldNodeHeight,rx:9,'class':'world-card',fill:'#102a40',stroke:'#36546b','stroke-width':1}));
        group.append(worldSvgNode('path',{d:'M1 13v50',stroke:worldColors[node.kind]||'#9db8ca','stroke-width':4,'stroke-linecap':'round'}),worldIcon(node.kind));
        group.append(worldSvgNode('text',{x:59,y:19,'class':'world-node-type'},worldShort(worldKindLabel(node),24).toUpperCase()),worldSvgNode('text',{x:59,y:39,'class':'world-node-label'},worldShort(node.label,node.canExpand?19:22)));
        const meta=node.kind==='group'?(node.count??'')+' objects'+(node.canExpand?' · '+(node.branchExpanded?'expanded':'expand'):''):String(worldStatus(node)||node.source||'Configuration');
        group.append(worldSvgNode('text',{x:59,y:59,'class':'world-node-meta'},worldShort(meta,24)));
        if(node.kind==='vm'||node.kind==='template')group.append(worldSvgNode('text',{x:59,y:70,'class':'world-node-extra'},get(node.row,'CpuCount','?')+' vCPU · '+get(node.row,'MemoryGiB','?')+' GiB'));
        if(node.canExpand){const control=worldSvgNode('g',{'class':'world-branch-toggle',transform:'translate(210 38)','aria-hidden':'true'});const vertical=worldOrientation==='vertical';const mark=vertical?(node.branchExpanded?'M-5 3L0-3L5 3':'M-5-3L0 3L5-3'):(node.branchExpanded?'M3-5L-3 0L3 5':'M-3-5L3 0L-3 5');control.append(worldSvgNode('circle',{r:11}),worldSvgNode('path',{d:mark}));group.append(control);}
        group.addEventListener('mouseenter',()=>{worldHovered=node.key;worldShowDetail(node);});group.addEventListener('mouseleave',()=>{worldHovered=null;const selected=worldGraph.nodes.find(item=>item.key===worldSelected);selected?worldShowDetail(selected):worldDefaultDetail();worldApplyHighlight();});
        group.addEventListener('focus',()=>{worldHovered=node.key;worldShowDetail(node);});group.addEventListener('blur',()=>{worldHovered=null;worldApplyHighlight();});
        group.addEventListener('click',event=>{if(event.detail>1)return;if(node.canExpand)worldExpand(node);else worldShowDetail(node,true);});group.addEventListener('dblclick',event=>event.preventDefault());
        group.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();if(node.canExpand)worldExpand(node);else worldShowDetail(node,true);}});worldScene.append(group);
      });
      document.getElementById('world-object-count').textContent=worldGraph.nodes.length+' objects · '+worldGraph.edges.length+' relationships'+(worldGraph.omitted?' · '+worldGraph.omitted+' grouped':'')+(worldGraph.hidden?' · '+worldGraph.hidden+' hidden':'');
      const selected=worldGraph.nodes.find(node=>node.key===worldSelected);selected?worldShowDetail(selected):worldDefaultDetail();worldApplyCamera();worldApplyHighlight();
    };
    const worldHandleWheel=event=>{
      event.preventDefault();const size=worldCameraSize();const px=event.clientX-size.left,py=event.clientY-size.top;
      const before=worldCamera.scale;const scale=Math.min(3.5,Math.max(.12,before*Math.exp(-event.deltaY*(event.deltaMode===1?.035:.0018))));
      worldCamera.x=px-(px-worldCamera.x)*scale/before;worldCamera.y=py-(py-worldCamera.y)*scale/before;worldCamera.scale=scale;
      const element=event.target.closest?.('.world-node');const node=element&&worldGraph.nodes.find(item=>item.key===element.getAttribute('data-key'));
      const owner=node&&(node.ref?.type==='vm'?node.ref:node.ownerRef?.type==='vm'?node.ownerRef:null);
      if(event.deltaY<0&&owner){const key=worldKey(owner),depth=scale>=1.7?2:scale>=.95?1:0;if(!worldCollapsed.has(key)&&depth>(worldVmDepth.get(key)||0)){worldVmDepth.set(key,depth);worldPreserveRender(key);}}
      worldApplyCamera();
    };
    function worldLocateConfigRef(ref){
      document.querySelector('nav [data-view="world"]').click();const key=worldKey(ref);worldSelected=key;worldHovered=null;worldSearch.value='';
      const owner=ref.type==='host'?ref:ref.type==='vm'?cfgExactRef('host',ref.source,get(ref.row,'HostId')):null;
      worldRevealed.add(key);if(owner)worldRevealed.add(worldKey(owner));worldRevealTarget=key;
      worldRender();const node=worldGraph.nodes.find(item=>item.key===key);if(node){const size=worldCameraSize();worldCamera.scale=1.05;worldCamera.x=size.width*.48-(node.x+worldNodeWidth/2)*worldCamera.scale;worldCamera.y=size.height*.38-(node.y+worldNodeHeight/2)*worldCamera.scale;worldInitialized=true;worldLastSize=size;worldShowDetail(node,true);worldApplyCamera();}
    }
    worldSvg.addEventListener('wheel',worldHandleWheel,{passive:false});
    worldSvg.addEventListener('pointerdown',event=>{if(event.button!==0||event.target.closest?.('.world-node'))return;worldDrag={pointer:event.pointerId,x:event.clientX,y:event.clientY,cameraX:worldCamera.x,cameraY:worldCamera.y};worldSvg.setPointerCapture?.(event.pointerId);worldViewport.classList.add('panning');});
    worldSvg.addEventListener('pointermove',event=>{if(!worldDrag)return;worldCamera.x=worldDrag.cameraX+event.clientX-worldDrag.x;worldCamera.y=worldDrag.cameraY+event.clientY-worldDrag.y;worldApplyCamera();});
    const worldEndDrag=()=>{worldDrag=null;worldViewport.classList.remove('panning');};worldSvg.addEventListener('pointerup',worldEndDrag);worldSvg.addEventListener('pointercancel',worldEndDrag);
    worldSearch.addEventListener('input',worldApplyHighlight);
    worldSearch.addEventListener('keydown',event=>{if(event.key==='Enter'){const query=worldSearch.value.trim().toLowerCase();const ref=query&&(cfgRefs.find(item=>item.label.toLowerCase()===query)||cfgRefs.find(item=>item.label.toLowerCase().includes(query)));if(ref){worldLocateConfigRef(ref);return;}const element=worldScene.querySelector('.world-node.search-match');if(element){const node=worldGraph.nodes.find(item=>item.key===element.getAttribute('data-key'));const size=worldCameraSize();worldCamera.scale=Math.max(.9,worldCamera.scale);worldCamera.x=size.width*.5-(node.x+worldNodeWidth/2)*worldCamera.scale;worldCamera.y=size.height*.35-(node.y+worldNodeHeight/2)*worldCamera.scale;worldShowDetail(node,true);worldApplyCamera();}}});
    worldViewport.addEventListener('keydown',event=>{if(event.target.closest?.('input,button'))return;if(event.key==='Home'){event.preventDefault();worldFit();}if(event.key==='Escape'){worldSelected=null;worldHovered=null;worldDefaultDetail();worldApplyHighlight();}const shift={ArrowLeft:[50,0],ArrowRight:[-50,0],ArrowUp:[0,50],ArrowDown:[0,-50]}[event.key];if(shift){event.preventDefault();worldCamera.x+=shift[0];worldCamera.y+=shift[1];worldApplyCamera();}});
    document.getElementById('world-reset').addEventListener('click',worldFit);
    worldOrientationButton.addEventListener('click',()=>{
      const vertical=worldOrientation!=='vertical';worldOrientation=vertical?'vertical':'horizontal';worldHovered=null;
      worldOrientationButton.textContent=vertical?'Layout: Top ↓ bottom':'Layout: Left → right';worldOrientationButton.setAttribute('aria-pressed',String(vertical));worldOrientationButton.title=vertical?'Switch to left-to-right layout':'Switch to top-to-bottom layout';
      worldSvg.dataset.orientation=worldOrientation;worldRender();worldFit();
    });
    document.getElementById('world-collapse').addEventListener('click',()=>{worldVmDepth.clear();worldHostConfig.clear();worldExpanded.clear();worldLimits.clear();worldRevealed.clear();worldCollapsed.clear();worldOpenBranches.clear();worldDrilldown=true;worldSelected=null;worldHovered=null;worldRender();worldFit();});
    document.getElementById('world-expand-estate').addEventListener('click',()=>{worldCollapsed.clear();worldOpenBranches.clear();worldDrilldown=false;worldHovered=null;worldRender();worldFit();});
    worldMini.addEventListener('click',event=>{const rect=worldMini.getBoundingClientRect();if(!rect.width||!rect.height)return;const fit=Math.min(rect.width/worldGraph.width,rect.height/worldGraph.height);const x=(event.clientX-rect.left-(rect.width-worldGraph.width*fit)/2)/fit,y=(event.clientY-rect.top-(rect.height-worldGraph.height*fit)/2)/fit;const size=worldCameraSize();worldCamera.x=size.width/2-x*worldCamera.scale;worldCamera.y=size.height/2-y*worldCamera.scale;worldApplyCamera();});
    // Fill the actual space below the heading; toolbar/footer reflow stays inside the panel.
    let worldResizeFrame=0;
    const worldResizePanel=()=>{
      if(!worldView.classList.contains('active'))return;
      const viewportHeight=window.visualViewport?.height||window.innerHeight,top=Math.max(0,worldPanel.getBoundingClientRect().top);
      const chrome=worldPanel.querySelector('.world-topbar').getBoundingClientRect().height+worldPanel.querySelector('.world-footer').getBoundingClientRect().height+2;
      const height=Math.max(360,Math.ceil(chrome+200),Math.floor(viewportHeight-top-16))+'px';
      if(worldPanel.style.getPropertyValue('--world-panel-height')!==height)worldPanel.style.setProperty('--world-panel-height',height);
      const size=worldCameraSize();
      if(!worldInitialized)worldFit();
      else{if(worldLastSize){worldCamera.x+=(size.width-worldLastSize.width)/2;worldCamera.y+=(size.height-worldLastSize.height)/2;}worldApplyCamera();}
      worldLastSize=size;
    };
    const worldScheduleResize=()=>{if(worldResizeFrame)return;worldResizeFrame=requestAnimationFrame(()=>{worldResizeFrame=0;worldResizePanel();});};
    document.querySelector('nav [data-view="world"]').addEventListener('click',worldScheduleResize);
    window.addEventListener('resize',worldScheduleResize);window.visualViewport?.addEventListener('resize',worldScheduleResize);
    if(typeof ResizeObserver==='function'){
      const observer=new ResizeObserver(worldScheduleResize);
      [worldView,worldPanel.querySelector('.world-topbar'),worldPanel.querySelector('.world-footer'),document.querySelector('.topbar')].filter(Boolean).forEach(element=>observer.observe(element));
    }
    document.fonts?.ready.then(worldScheduleResize);
    window.vcfDmExplorer=Object.freeze({configurationCounts:Object.freeze(Object.fromEntries([...cfgSets].map(([key,set])=>[key,set.refs.length]))),worldNavigation:'persistent layered topology',relationshipMode:'native-id-first; unique source-and-name fallback for legacy snapshots',getWorldGraph:()=>({orientation:worldOrientation,nodes:worldGraph.nodes.map(node=>({key:node.key,kind:node.kind,label:node.label,source:node.source,parent:node.parent,owner:node.ownerKey,canExpand:node.canExpand,expanded:node.branchExpanded,x:node.x,y:node.y})),edges:worldGraph.edges.map(edge=>({...edge})),width:worldGraph.width,height:worldGraph.height}),getWorldCamera:()=>({...worldCamera})});
    worldSvg.dataset.orientation=worldOrientation;worldRender();worldResizePanel();
