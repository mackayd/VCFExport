    // Shared presentation layer. It never alters snapshot values or export payloads.
    function appStatusTone(value){
      const state=String(value??'').toUpperCase().replace(/[\s_-]/g,'');
      if(['FAILED','COLLECTIONFAILED','CRITICAL','EXPIRED','UNREACHABLE','NOTAUTHORIZED','ERROR','RED','DISCONNECTED'].includes(state))return 'bad';
      if(['PARTIAL','REPORTPARTIALLYCOMPLETE','WARNING','YELLOW','DEGRADED','MAINTENANCE','EXPIRING'].includes(state))return 'warn';
      if(['SUCCESS','REPORTCOMPLETE','COMPLETE','ACTIVE','GREEN','STABLE','ASSIGNED','UP','CONNECTED','POWEREDON'].includes(state))return 'good';
      return '';
    }
    function appObjectIcon(ref,className='page-icon'){
      const icon=worldSvgNode('svg',{viewBox:'0 0 64 74','class':className,'aria-hidden':'true'});icon.append(worldIcon(infraKind(ref)));return icon;
    }
    function appFactTiles(pairs){const box=make('div','ui-facts');pairs.forEach(([label,value])=>{const tile=make('div','ui-fact');tile.append(make('span','',label),make('strong','',value));box.append(tile);});return box;}
    function appConfigFacts(ref){return appFactTiles(worldFactPairs({kind:infraKind(ref),row:ref.row,source:ref.source,ref,key:worldKey(ref)}));}
    function appDecorateDetail(container,row,dataset){
      const title=container.querySelector('h3'),properties=container.querySelector('.kv');if(!title||!properties)return;
      const source=cfgSource(row);const ref=cfgExactRef('vm',source,get(row,'VMId'))||cfgExactRef('host',source,get(row,'HostId'));
      const heading=make('div','ui-detail-heading');heading.append(appObjectIcon(ref||{type:'component'}));const labels=document.createElement('div');labels.append(title,make('p','',dataset+' · '+(source||'Source not captured')));heading.append(labels);container.prepend(heading);
      if(ref)container.insertBefore(appConfigFacts(ref),properties);
      const details=make('details','ui-property-details');details.append(make('summary','','All captured fields · '+Object.keys(row).length));container.insertBefore(details,properties);details.append(properties);
    }
    const appPageInfo={
      overview:['Estate intelligence','group'],world:['Connected topology','network'],explorer:['Infrastructure navigation','domain'],
      virtual:['Object configuration','host'],detailed:['Detailed inventory','group'],lifecycle:['Lifecycle intelligence','component'],
      findings:['Evidence & attention','component'],inventory:['Captured datasets','group'],collection:['Collection confidence','component']
    };
    const appIcon=(kind,className)=>{const icon=worldSvgNode('svg',{viewBox:'0 0 64 74','class':className,'aria-hidden':'true'});icon.append(worldIcon(kind));return icon;};
    document.querySelectorAll('nav [data-view]').forEach(button=>{const title=button.textContent;button.textContent='';button.append(appIcon(appPageInfo[button.dataset.view][1],'nav-icon'),make('span','',title));});
    document.querySelectorAll('main>.view').forEach(view=>{
      const title=view.querySelector(':scope>h2');if(!title)return;const id=view.id.slice(5),info=appPageInfo[id];const heading=make('div','page-heading');heading.append(appIcon(info[1],'page-icon'));const content=document.createElement('div');content.append(make('span','page-eyebrow',info[0]),title);const description=view.querySelector(':scope>.lede');if(description)content.append(description);heading.append(content);view.prepend(heading);
    });
    document.querySelectorAll('.cards>.card').forEach(card=>{
      const label=card.querySelector('.label')?.textContent||'',value=card.querySelector('.value')?.textContent||'';
      const kind=/host/i.test(label)?'host':/cluster|domain/i.test(label)?'cluster':/virtual machine/i.test(label)?'vm':/datastore/i.test(label)?'datastore':/instance/i.test(label)?'instance':/release|latest|drift/i.test(label)?'component':'group';
      card.append(appIcon(kind,'metric-icon'));if(value.length>18||!/^\d[\d,.]*(?:\s|$)/.test(value))card.classList.add('compact-value');if(['Critical','Warning','Info'].includes(label))card.classList.add('severity-'+label.toLowerCase());
    });
    const capture=document.getElementById('app-capture-time');const date=new Date(snapshot.CollectedUTC);
    capture.textContent=Number.isNaN(date.getTime())?'Capture time not recorded':'Captured '+date.toLocaleString('en-GB',{timeZone:'UTC',year:'numeric',month:'short',day:'2-digit',hour:'2-digit',minute:'2-digit'})+' UTC';
    appUiReady=true;cfgRenderList();const firstConfig=cfgVmRefs[0]||cfgHostRefs[0]||cfgClusterRefs[0];if(firstConfig&&!cfgSelectedRef)cfgSelectRef(firstConfig);
    document.documentElement.dataset.uiTheme='vcf-estate';
    // Fit the explorer to its actual position, including wrapped headings and browser zoom.
    const appExplorerView=document.getElementById('view-explorer');
    const appExplorerWorkspace=appExplorerView.querySelector('.infra-workspace');
    let appExplorerResizeFrame=0;
    const appFitExplorer=()=>{
      if(window.innerWidth<=750){appExplorerWorkspace.style.removeProperty('--infra-workspace-height');return;}
      if(!appExplorerView.classList.contains('active'))return;
      const viewportHeight=window.visualViewport?.height||window.innerHeight;
      const top=Math.max(0,appExplorerWorkspace.getBoundingClientRect().top);
      const height=Math.max(320,Math.floor(viewportHeight-top-16))+'px';
      if(appExplorerWorkspace.style.getPropertyValue('--infra-workspace-height')!==height)appExplorerWorkspace.style.setProperty('--infra-workspace-height',height);
    };
    const appScheduleExplorerFit=()=>{if(appExplorerResizeFrame)return;appExplorerResizeFrame=requestAnimationFrame(()=>{appExplorerResizeFrame=0;appFitExplorer();});};
    window.addEventListener('resize',appScheduleExplorerFit);
    window.visualViewport?.addEventListener('resize',appScheduleExplorerFit);
    document.querySelector('nav [data-view="explorer"]').addEventListener('click',appScheduleExplorerFit);
    if(typeof ResizeObserver==='function'){
      const observer=new ResizeObserver(appScheduleExplorerFit);
      [document.querySelector('.topbar'),appExplorerView.querySelector('.page-heading'),appExplorerWorkspace.querySelector('.infra-topbar')].filter(Boolean).forEach(element=>observer.observe(element));
    }
    document.fonts?.ready.then(appScheduleExplorerFit);
    appFitExplorer();
